# frozen_string_literal: true

class SessionsController < ApplicationController
  include AuthRateLimiting
  include SuccessfulSignIn

  # CSRF protection is enabled (removed skip_before_action for security)
  before_action :rate_limit_login!, only: [:create]

  # Precomputed bcrypt digest, only used to equalize failed-login response time
  # for non-existent emails so timing can't reveal whether an account exists.
  # Random input → never matches a real password.
  TIMING_EQUALIZER_DIGEST = BCrypt::Password.create(SecureRandom.hex(32)).to_s.freeze

  def new
    redirect_to root_path if current_user
  end

  def create
    user = User.find_by(email: params[:email]&.downcase)

    # Check if account is locked
    if user&.locked?
      minutes_remaining = ((user.locked_until - Time.current) / 60).ceil
      flash.now[:alert] = t('auth.account_locked', minutes: minutes_remaining)
      render :new, status: :unprocessable_entity
      return
    end

    authenticated = if user
                      begin
                        user.authenticate(params[:password])
                      rescue BCrypt::Errors::InvalidHash
                        Rails.logger.error("Corrupted password_digest for user #{user.id}")
                        false
                      end
                    else
                      # No such email: burn an equivalent bcrypt so the response
                      # time matches the account-exists path (anti-enumeration).
                      BCrypt::Password.new(TIMING_EQUALIZER_DIGEST) == params[:password].to_s
                      false
                    end

    if authenticated
      # Admin-only accounts cannot log in via regular site - silently reject
      admin_emails = ENV.fetch('ADMIN_EMAILS', '').split(',').map(&:strip).map(&:downcase)
      if admin_emails.include?(user.email.downcase)
        flash.now[:alert] = t('auth.invalid_credentials')
        render :new, status: :unprocessable_entity
        return
      end

      # WW-ABUSE-01: the holder of a suspended account learns only that
      # access is unavailable: no reactivation offer, no confirmation resend,
      # no reason.
      if user.abuse_suspended?
        flash.now[:alert] = t('auth.access_unavailable')
        render :new, status: :unprocessable_entity
        return
      end

      unless user.confirmed?
        @unconfirmed_email = user.email
        flash.now[:alert] = t('auth.not_confirmed')
        render :new, status: :unprocessable_entity
        return
      end

      if user.active?
        user.reset_failed_attempts!

        # Check if 2FA is enabled
        if user.otp_enabled?
          # Keep authentication state out of the CSRF-only Rails session.
          # WW-SEC-12: a challenge bound to the account's current credentials,
          # newest-only and single-use (PendingSecondFactor). One this browser
          # held before ends first, or nothing new starts: a challenge that
          # could not be cancelled keeps its cookie. No challenge at all when
          # the credentials changed after the password above was checked:
          # that password no longer proves anything.
          unless cancel_pending_sign_in!
            flash.now[:alert] = t('auth.pending_sign_in_not_replaced')
            render :new, status: :service_unavailable
            return
          end
          challenge = PendingSecondFactor.issue(user, purpose: :user)
          unless challenge
            flash.now[:alert] = t('auth.invalid_credentials')
            render :new, status: :unprocessable_entity
            return
          end
          cookies.encrypted[:pending_2fa_user_id] = { value: challenge,
                                                      expires: PendingSecondFactor::LIFETIME.from_now, httponly: true,
                                                      secure: Rails.env.production?, same_site: :lax }
          cookies.signed[:remember_me] = { value: params[:remember_me] == '1', expires: 5.minutes.from_now, httponly: true, secure: Rails.env.production?, same_site: :lax }
          redirect_to challenge_2fa_path, status: :see_other
          return
        end

        # ABA-004: the shared writer owns token + projection + brand + the one
        # 'login' activity, in one transaction, cookie only after commit.
        record_successful_sign_in!(user, remember: params[:remember_me] == '1')

        # Check for pending Pro subscription (selected during registration)
        if cookies.signed[:pending_pro].present?
          interval = cookies.signed[:pending_pro_interval] || 'monthly'
          cookies.delete(:pending_pro)
          cookies.delete(:pending_pro_interval)
          redirect_to checkout_path(tier: 'pro', interval: interval), notice: t('auth.signed_in'), status: :see_other
          return
        end

        redirect_to safe_redirect_path(params[:redirect_to]), notice: t('auth.signed_in'), status: :see_other
      else
        @deactivated_email = user.email
        flash.now[:alert] = t('auth.account_disabled')
        render :new, status: :unprocessable_entity
      end
    else
      # Record failed login attempt
      if user
        user.record_failed_login!
        AccountActivity.log(user, 'failed_login', request)
        if user.locked?
          AccountActivity.log(user, 'account_locked', request)
          flash.now[:alert] = t('auth.account_locked', minutes: 15)
        else
          flash.now[:alert] = t('auth.invalid_credentials')
        end
      else
        flash.now[:alert] = t('auth.invalid_credentials')
      end
      render :new, status: :unprocessable_entity
    end
  end

  def reactivate
    user = User.find_by(email: params[:email]&.downcase)

    # Only a confirmed account can be reactivated (WW-ABUSE-01, 2026-10-06):
    # an unconfirmed one was never usable, and an admin-deactivated
    # unconfirmed registration would otherwise mail itself a way back in.
    # The response stays the same either way.
    if user && !user.active? && user.confirmed? && user.activatable?
      # Generate a reactivation token (reuse confirmation_token column)
      token = user.generate_confirmation_token!
      UserMailer.reactivation_email(user, token).deliver_later
      flash[:notice] = t('auth.reactivation_email_sent', default: 'A reactivation email has been sent. Check your inbox.')
    else
      # Don't reveal whether user exists
      flash[:notice] = t('auth.reactivation_email_sent', default: 'A reactivation email has been sent. Check your inbox.')
    end

    redirect_to login_path, status: :see_other
  end

  def confirm_reactivation
    user = User.find_by(confirmation_token: params[:token])

    # Expire the link like the email-confirmation flow does (72h). Without this
    # a leaked/forwarded reactivation email could silently re-enable a
    # deletion-scheduled account indefinitely.
    if user && (user.confirmation_sent_at.nil? || user.confirmation_sent_at < 72.hours.ago)
      flash[:alert] = t('auth.invalid_reactivation_link', default: 'This reactivation link is invalid or expired.')
      redirect_to login_path
      return
    end

    # The registration, reactivation and deletion-warning tokens share one
    # column, so a signup confirmation link would reactivate too: an
    # unconfirmed account is refused with the generic answer (WW-ABUSE-01).
    if user && !user.active? && user.confirmed? && user.activatable?
      user.update!(
        active: true,
        deletion_scheduled_for: nil,
        deletion_reason: nil,
        confirmation_token: nil
      )
      AccountActivity.log(user, 'account_reactivated', request)
      flash[:notice] = t('auth.account_reactivated', default: 'Your account has been reactivated. You can now log in.')
      redirect_to login_path
    else
      flash[:alert] = t('auth.invalid_reactivation_link', default: 'This reactivation link is invalid or expired.')
      redirect_to login_path
    end
  end

  def destroy
    AccountActivity.log(current_user, 'logout', request) if current_user
    if sign_out
      redirect_to root_path, notice: t('auth.signed_out'), status: :see_other
    else
      redirect_to root_path, alert: t('auth.pending_sign_in_not_cancelled'), status: :see_other
    end
  end

  private

  # Ends the session, then any pending second-factor challenge, separately:
  # false when the challenge could not be cancelled on the server (the
  # session is still ended, and the caller says so).
  def sign_out
    current_user&.clear_session_token!
    cookies.delete(:session_token)
    # WW-SEC-12/13: no half-finished sign-in or 2FA enrolment outlives the
    # session; the pending challenge ends on the server too.
    cancelled = cancel_pending_sign_in!
    %i[remember_me pending_otp_secret].each { |name| cookies.delete(name) }
    cancelled
  end

  # Prevent open redirect attacks by only allowing relative paths
  def safe_redirect_path(path)
    return root_path if path.blank?

    # Same-origin paths only: must start with a single '/' followed by a char
    # that is NOT '/' or '\'. Blocks '//evil.com' AND '/\evil.com': browsers
    # normalize the backslash to '/', turning the latter into a protocol-
    # relative open redirect that the old start_with?('//') check let through.
    path.match?(%r{\A/(?![/\\])}) ? path : root_path
  end
end
