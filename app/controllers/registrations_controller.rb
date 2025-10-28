# frozen_string_literal: true

class RegistrationsController < ApplicationController
  # CSRF protection is enabled (removed skip_before_action for security)

  def new
    redirect_to root_path if current_user
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    @user.locale = I18n.locale.to_s

    if @user.save
      # Send confirmation email
      @user.generate_confirmation_token!
      UserMailer.confirmation_email(@user).deliver_later
      
      redirect_to login_path, notice: t('auth.confirmation_sent')
    else
      render :new, status: :unprocessable_entity
    end
  end

  def confirm
    user = User.find_by(confirmation_token: params[:token])

    if user && user.confirmation_sent_at > 24.hours.ago
      user.confirm!
      redirect_to login_path, notice: t('auth.email_confirmed')
    else
      redirect_to root_path, alert: t('auth.invalid_token')
    end
  end

  def resend_confirmation
    if current_user && !current_user.confirmed?
      current_user.generate_confirmation_token!
      UserMailer.confirmation_email(current_user).deliver_later
      redirect_back fallback_location: root_path, notice: t('auth.confirmation_resent')
    else
      redirect_to root_path
    end
  end

  private

  def user_params
    params.require(:user).permit(:email, :password, :password_confirmation, :name, :terms_accepted)
  end

  def sign_in(user)
    token = user.generate_session_token!
    cookies.signed[:session_token] = {
      value: token,
      expires: 30.days.from_now,
      httponly: true,
      secure: Rails.env.production?
    }
  end
end
