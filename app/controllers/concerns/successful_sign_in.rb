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

  def record_successful_sign_in!(user, remember:)
    site_brand = SiteBrand.resolve_request(request)
    if site_brand.nil?
      Rails.logger.warn('[BRAND-ATTRIBUTION] sign-in on unresolved host; stored NULL')
    end

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

    cookies.signed[:session_token] = {
      value: token,
      expires: remember ? 30.days.from_now : 2.hours.from_now,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
  end
end
