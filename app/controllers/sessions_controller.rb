# frozen_string_literal: true

class SessionsController < ApplicationController
  include AuthRateLimiting

  # CSRF protection is enabled (removed skip_before_action for security)
  before_action :rate_limit_login!, only: [:create]

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

    authenticated = begin
      user&.authenticate(params[:password])
    rescue BCrypt::Errors::InvalidHash
      Rails.logger.error("Corrupted password_digest for user #{user&.id}")
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
          # Use signed cookies instead of sessions (sessions are disabled for privacy)
          cookies.signed[:pending_2fa_user_id] = { value: user.id, expires: 5.minutes.from_now, httponly: true, secure: Rails.env.production?, same_site: :lax }
          cookies.signed[:remember_me] = { value: params[:remember_me] == '1', expires: 5.minutes.from_now, httponly: true, secure: Rails.env.production?, same_site: :lax }
          redirect_to challenge_2fa_path, status: :see_other
          return
        end

        sign_in(user, remember: params[:remember_me] == '1')
        AccountActivity.log(user, 'login', request)

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

    if user && !user.active?
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

    if user && !user.active?
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
    sign_out
    redirect_to root_path, notice: t('auth.signed_out'), status: :see_other
  end

  private

  def sign_in(user, remember: false)
    token = user.generate_session_token!
    user.update!(last_sign_in_at: Time.current, last_sign_in_ip: request.remote_ip, last_activity_at: Time.current)
    cookies.signed[:session_token] = {
      value: token,
      expires: remember ? 30.days.from_now : 2.hours.from_now,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
  end

  def sign_out
    current_user&.clear_session_token!
    cookies.delete(:session_token)
  end

  # Prevent open redirect attacks by only allowing relative paths
  def safe_redirect_path(path)
    return root_path if path.blank?

    # Only allow paths starting with / and not // (protocol-relative URLs)
    path.start_with?('/') && !path.start_with?('//') ? path : root_path
  end
end
