# frozen_string_literal: true

class TwoFactorController < ApplicationController
  include AuthRateLimiting
  include SuccessfulSignIn

  before_action :require_authentication, except: %i[challenge verify]
  before_action :rate_limit_2fa!, only: [:verify]

  # WW-SEC-13: enrolment is bound to its account. The pending secret lives in
  # an encrypted cookie (never readable), tied to this account and to its
  # credentials at setup time; enabling needs the account password, as
  # switching 2FA off does; and an enrolled factor is never overwritten here:
  # replacing it means switching it off first.
  ENROLMENT_LIFETIME = 10.minutes

  def setup
    @user = current_user
    return redirect_to(account_path, alert: t('account.2fa_replace_first')) if @user.otp_enabled?

    @otp_secret = ROTP::Base32.random
    cookies.encrypted[:pending_otp_secret] = {
      value: { 'user' => @user.id, 'secret' => @otp_secret, 'binding' => enrolment_binding(@user, @otp_secret) },
      expires: ENROLMENT_LIFETIME.from_now, httponly: true, secure: Rails.env.production?, same_site: :lax
    }

    @qr_code = generate_qr_code(@otp_secret)
  end

  def enable
    @user = current_user
    return redirect_to(account_path, alert: t('account.2fa_replace_first')) if @user.otp_enabled?

    backup_codes = 10.times.map { SecureRandom.hex(4).upcase }
    # WW-SEC-13 refinement: every check reads the account under its row lock,
    # so a password change or a parallel enable cannot land between the checks
    # and the write. Two parallel enables: the lock lets one through.
    verdict, otp_secret = @user.with_lock do
      next [:enabled_already] if @user.otp_enabled?

      secret = pending_enrolment_secret
      next [:expired] unless secret
      next [:wrong_password, secret] unless @user.authenticate(params[:password].to_s)
      next [:wrong_code, secret] unless ROTP::TOTP.new(secret, issuer: 'WetWijzer')
                                                  .verify(params[:otp_code], drift_behind: 30, drift_ahead: 30)

      @user.update!(otp_secret: secret, otp_enabled: true, otp_backup_codes: backup_codes.to_json)
      [:enrolled]
    end

    case verdict
    when :expired then return redirect_to(setup_2fa_path, alert: t('account.2fa_setup_expired'))
    when :wrong_password then return render_setup_again(otp_secret, t('account.wrong_password'))
    when :wrong_code then return render_setup_again(otp_secret, t('account.invalid_otp'))
    end
    cookies.delete(:pending_otp_secret)
    return redirect_to(account_path, alert: t('account.2fa_replace_first')) unless verdict == :enrolled

    AccountActivity.log(@user, 'otp_enabled', request)

    @backup_codes = backup_codes
    render :backup_codes
  end

  def disable
    @user = current_user

    # Require password re-verification before disabling 2FA
    unless @user.authenticate(params[:password])
      redirect_to account_path, alert: t('account.wrong_password')
      return
    end

    @user.update!(
      otp_secret: nil,
      otp_enabled: false,
      otp_backup_codes: nil
    )

    AccountActivity.log(@user, 'otp_disabled', request)
    redirect_to account_path, notice: t('account.2fa_disabled')
  end

  def challenge
    return if cookies.encrypted[:pending_2fa_user_id]

    redirect_to login_path
    nil
  end

  def verify
    # WW-SEC-12: one serialized completion boundary (PendingSecondFactor):
    # the newest challenge against the account's current credentials, the
    # account checks, the code, the one-time claim and the session, under the
    # account lock. The cookie is published only after it commits.
    token = nil
    outcome = PendingSecondFactor.complete(
      cookies.encrypted[:pending_2fa_user_id],
      purpose: :user,
      verify: lambda do |user|
        # WW-SEC-04: the password step checked the account minutes ago. A
        # deactivation, a withdrawn confirmation, a lock, 2FA switched off or an
        # abuse suspension (WW-ABUSE-01) can land between the two steps, so the
        # pending cookie never finishes a sign-in without a fresh check, and a
        # refused one is spent.
        next :refused unless user.active? && user.confirmed? && !user.locked? &&
                             user.otp_enabled? && user.activatable?

        totp = ROTP::TOTP.new(user.otp_secret, issuer: 'WetWijzer')
        totp.verify(params[:otp_code], drift_behind: 30, drift_ahead: 30).present? ||
          verify_backup_code(user, params[:otp_code])
      end,
      finish: ->(user) { token = persist_successful_sign_in!(user) }
    )

    case outcome.status
    when :completed then complete_sign_in(token)
    when :wrong_code
      @user = outcome.user
      flash.now[:alert] = t('account.invalid_otp')
      render :challenge
    else expire_pending_sign_in!
    end
  end

  private

  # The enrolment secret, only for this account, its unchanged credentials
  # and within the cookie's lifetime; else nil.
  def pending_enrolment_secret
    pending = cookies.encrypted[:pending_otp_secret]
    return nil unless pending.is_a?(Hash) && pending['user'] == current_user.id

    secret = pending['secret'].to_s
    return nil unless secret.match?(/\A[A-Z2-7]{16,64}\z/)
    return nil unless ActiveSupport::SecurityUtils.secure_compare(enrolment_binding(current_user, secret),
                                                                  pending['binding'].to_s)

    secret
  end

  def enrolment_binding(user, secret)
    @enrolment_key ||= Rails.application.key_generator.generate_key('two-factor-enrolment v1', 32)
    OpenSSL::HMAC.hexdigest('SHA256', @enrolment_key, [user.id, user.password_digest, user.otp_secret, secret].join('|'))
  end

  # Wrong password or code: the same secret again, so the authenticator the
  # reader has just scanned stays valid.
  def render_setup_again(otp_secret, message)
    @otp_secret = otp_secret
    @qr_code = generate_qr_code(otp_secret)
    flash.now[:alert] = message
    render :setup, status: :unprocessable_entity
  end

  def expire_pending_sign_in!
    cancel_pending_sign_in!
    cookies.delete(:remember_me)
    redirect_to login_path, alert: t('auth.session_expired')
  end

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
    user.consume_backup_code!(code)
  end

  # ABA-004: the shared writer owns token + projection + brand + the one
  # 'login' activity. A 2FA login is attributed at the completed challenge
  # (persisted inside the completion boundary); the password step wrote
  # nothing. This is the browser half.
  def complete_sign_in(token)
    remember = cookies.signed[:remember_me]
    cookies.delete(:remember_me)
    publish_sign_in!(token, remember: remember)

    # Check for pending Pro subscription (selected during registration)
    if cookies.signed[:pending_pro].present?
      interval = cookies.signed[:pending_pro_interval] || 'monthly'
      cookies.delete(:pending_pro)
      cookies.delete(:pending_pro_interval)
      redirect_to checkout_path(tier: 'pro', interval: interval), notice: t('auth.signed_in')
    else
      redirect_to chatbot_path, notice: t('auth.signed_in')
    end
  end
end
