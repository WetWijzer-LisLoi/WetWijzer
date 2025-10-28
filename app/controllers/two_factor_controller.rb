# frozen_string_literal: true

class TwoFactorController < ApplicationController
  before_action :require_authentication, except: [:challenge, :verify]

  def setup
    @user = current_user
    # Generate a new OTP secret if not already set
    @otp_secret = ROTP::Base32.random
    # Use signed cookies instead of sessions (sessions are disabled for privacy)
    cookies.signed[:pending_otp_secret] = { value: @otp_secret, expires: 10.minutes.from_now, httponly: true }
    
    @qr_code = generate_qr_code(@otp_secret)
  end

  def enable
    @user = current_user
    otp_secret = cookies.signed[:pending_otp_secret]
    
    unless otp_secret
      redirect_to setup_2fa_path, alert: t('account.2fa_setup_expired')
      return
    end

    totp = ROTP::TOTP.new(otp_secret, issuer: 'WetWijzer')
    
    if totp.verify(params[:otp_code], drift_behind: 30, drift_ahead: 30)
      # Generate backup codes
      backup_codes = 10.times.map { SecureRandom.hex(4).upcase }
      
      @user.update!(
        otp_secret: otp_secret,
        otp_enabled: true,
        otp_backup_codes: backup_codes.to_json
      )
      
      cookies.delete(:pending_otp_secret)
      AccountActivity.log(@user, 'otp_enabled', request)
      
      @backup_codes = backup_codes
      render :backup_codes
    else
      redirect_to setup_2fa_path, alert: t('account.invalid_otp')
    end
  end

  def disable
    @user = current_user
    
    @user.update!(
      otp_secret: nil,
      otp_enabled: false,
      otp_backup_codes: nil
    )
    
    AccountActivity.log(@user, 'otp_disabled', request)
    redirect_to account_path, notice: t('account.2fa_disabled')
  end

  def challenge
    unless cookies.signed[:pending_2fa_user_id]
      redirect_to login_path
      return
    end
  end

  def verify
    user_id = cookies.signed[:pending_2fa_user_id]
    unless user_id
      redirect_to login_path, alert: t('auth.session_expired')
      return
    end
    
    @user = User.find(user_id)
    totp = ROTP::TOTP.new(@user.otp_secret, issuer: 'WetWijzer')
    
    if totp.verify(params[:otp_code], drift_behind: 30, drift_ahead: 30)
      cookies.delete(:pending_2fa_user_id)
      complete_sign_in(@user)
    elsif verify_backup_code(@user, params[:otp_code])
      cookies.delete(:pending_2fa_user_id)
      complete_sign_in(@user)
    else
      flash.now[:alert] = t('account.invalid_otp')
      render :challenge
    end
  rescue ActiveRecord::RecordNotFound
    cookies.delete(:pending_2fa_user_id)
    redirect_to login_path, alert: t('auth.session_expired')
  end

  private

  def generate_qr_code(secret)
    totp = ROTP::TOTP.new(secret, issuer: 'WetWijzer')
    uri = totp.provisioning_uri(current_user.email)
    
    # Generate QR code as SVG
    qr = RQRCode::QRCode.new(uri)
    qr.as_svg(
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 4,
      standalone: true,
      use_path: true
    )
  end

  def verify_backup_code(user, code)
    return false unless user.otp_backup_codes.present?
    
    codes = JSON.parse(user.otp_backup_codes)
    if codes.include?(code.upcase)
      codes.delete(code.upcase)
      user.update!(otp_backup_codes: codes.to_json)
      true
    else
      false
    end
  end

  def complete_sign_in(user)
    remember = cookies.signed[:remember_me]
    cookies.delete(:remember_me)
    token = user.generate_session_token!
    user.update!(last_sign_in_at: Time.current, last_sign_in_ip: request.remote_ip, last_activity_at: Time.current)
    cookies.signed[:session_token] = {
      value: token,
      expires: remember ? 30.days.from_now : 2.hours.from_now,
      httponly: true,
      secure: Rails.env.production?
    }
    AccountActivity.log(user, 'login', request)
    redirect_to chatbot_path, notice: t('auth.signed_in')
  end
end
