# frozen_string_literal: true

class SessionsController < ApplicationController
  # CSRF protection is enabled (removed skip_before_action for security)

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

    if user&.authenticate(params[:password])
      unless user.confirmed?
        flash.now[:alert] = t('auth.not_confirmed')
        render :new, status: :unprocessable_entity
        return
      end
      
      if user.active?
        user.reset_failed_attempts!
        
        # Check if 2FA is enabled
        if user.otp_enabled?
          # Use signed cookies instead of sessions (sessions are disabled for privacy)
          cookies.signed[:pending_2fa_user_id] = { value: user.id, expires: 5.minutes.from_now, httponly: true }
          cookies.signed[:remember_me] = { value: params[:remember_me] == '1', expires: 5.minutes.from_now, httponly: true }
          redirect_to challenge_2fa_path
          return
        end
        
        sign_in(user, remember: params[:remember_me] == '1')
        AccountActivity.log(user, 'login', request)
        redirect_to params[:redirect_to] || chatbot_path, notice: t('auth.signed_in')
      else
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
          flash.now[:alert] = t('auth.account_locked', minutes: 30)
        else
          attempts_left = User::MAX_FAILED_ATTEMPTS - user.failed_attempts
          flash.now[:alert] = t('auth.invalid_credentials_with_attempts', attempts: attempts_left)
        end
      else
        flash.now[:alert] = t('auth.invalid_credentials')
      end
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    AccountActivity.log(current_user, 'logout', request) if current_user
    sign_out
    redirect_to root_path, notice: t('auth.signed_out')
  end

  private

  def sign_in(user, remember: false)
    token = user.generate_session_token!
    user.update!(last_sign_in_at: Time.current, last_sign_in_ip: request.remote_ip, last_activity_at: Time.current)
    cookies.signed[:session_token] = {
      value: token,
      expires: remember ? 30.days.from_now : 2.hours.from_now,
      httponly: true,
      secure: Rails.env.production?
    }
  end

  def sign_out
    current_user&.clear_session_token!
    cookies.delete(:session_token)
  end
end
