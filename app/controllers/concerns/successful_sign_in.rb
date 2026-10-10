# frozen_string_literal: true

# ABA-004: THE one writer for a fully successful sign-in. Password login and
# completed 2FA used to duplicate this dance line for line (token, projection
# update, cookie, activity) - two call-sites that could only drift apart.
#
# One accounts transaction owns all the database writes: session token, the
# last_sign_in_* projection including the brand, and exactly one 'login'
# activity carrying the same brand. The browser cookie is set only AFTER that
# transaction commits, so a failed write can never leave a signed-in browser
# pointing at a session the database never recorded.
#
# The brand comes from request.host through SiteBrand at the moment of the
# COMPLETED authentication - for 2FA that is the successful challenge, not the
# password step. An unresolved host stores NULL on both writes and never
# blocks the sign-in; the warning is content-free by contract (no host, no
# identity).
module SuccessfulSignIn
  extend ActiveSupport::Concern

  private

  # WW-ABUSE-01: the one session writer refuses a suspended account outright;
  # its callers check first, this is the last fence.
  class SuspendedAccountSignIn < StandardError; end

  def record_successful_sign_in!(user, remember:)
    token = persist_successful_sign_in!(user)
    publish_sign_in!(token, remember: remember)
  end

  # The database half; returns the session token. A completed second factor
  # runs it inside PendingSecondFactor's completion boundary, so the fence
  # below covers password sign-in and 2FA completion alike.
  def persist_successful_sign_in!(user)
    raise SuspendedAccountSignIn, 'abuse-suspended account' unless user.activatable?

    site_brand = SiteBrand.resolve_request(request)
    Rails.logger.warn('[BRAND-ATTRIBUTION] sign-in on unresolved host; stored NULL') if site_brand.nil?

    token = nil
    AccountRecord.transaction do
      token = user.generate_session_token!
      user.update!(
        last_sign_in_at: Time.current,
        last_sign_in_ip: request.remote_ip,
        last_activity_at: Time.current,
        last_sign_in_brand: site_brand
      )
      AccountActivity.log(user, 'login', request, site_brand: site_brand)
    end
    token
  end

  # The browser half, only after the database half has committed.
  def publish_sign_in!(token, remember:)
    write_session_cookie!(token, remember: remember)
    # WW-SEC-12/13: signing in, to this account or another, ends any other
    # pending sign-in or 2FA enrolment this browser was holding.
    cancel_pending_sign_in!
    cookies.delete(:pending_otp_secret)
  end

  # WW-SEC-12: the server-side challenge ends with its cookie, so a copy of
  # the cookie cannot finish the sign-in later. A newer challenge stays live.
  # The cancellation is durable (the accounts database); when it cannot be
  # written, it is logged, the cookie stays, and the caller learns it (false).
  def cancel_pending_sign_in!
    PendingSecondFactor.cancel(cookies.encrypted[:pending_2fa_user_id], purpose: :user)
    cookies.delete(:pending_2fa_user_id)
    true
  rescue ActiveRecord::ActiveRecordError => e
    SecurityLog.warn('pending_sign_in_cancel_failed', request: request, error: e.class.name)
    false
  end

  def write_session_cookie!(token, remember:)
    cookies.signed[:session_token] = {
      value: token,
      expires: remember ? 30.days.from_now : 2.hours.from_now,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
  end
end
