# frozen_string_literal: true

class RegistrationsController < ApplicationController
  include AuthRateLimiting

  # One-time credits granted to new accounts for alpha testing
  # Allows users to try higher-tier AI models (Level II/Level III/Level IV)
  STARTER_CREDITS = 5

  # CSRF protection is enabled (removed skip_before_action for security)
  before_action :require_production_environment, only: %i[new create]
  before_action :rate_limit_registration!, only: [:create]

  def new
    redirect_to root_path if current_user
    @user = User.new
  end

  def create
    # Honeypot bot protection: reject if hidden field is filled
    if params[:website].present?
      Rails.logger.warn("[REGISTRATION] Bot detected (honeypot filled) from #{request.remote_ip}")
      redirect_to root_path and return
    end

    email = params.dig(:user, :email)&.downcase&.strip

    # Duplicate registrations must be indistinguishable from fresh ones
    # (FBL-044): the old inline "already registered" error told any visitor
    # whether an address has an account. Now both paths land on the same
    # "check your email" page; the existing owner gets a security alert
    # instead of a confirmation, rate-limited to one per day so repeated
    # probing cannot mail-bomb the victim.
    existing_user = User.find_by(email: email)
    if existing_user
      Rails.logger.info("[REGISTRATION] Duplicate registration attempt from #{request.remote_ip}")
      alert_gate_key = "registration_alert:#{existing_user.id}"
      unless Rails.cache.exist?(alert_gate_key)
        Rails.cache.write(alert_gate_key, true, expires_in: 24.hours)
        UserMailer.security_alert(
          existing_user,
          'registration_attempt',
          { ip: request.remote_ip, user_agent: request.user_agent }
        ).deliver_later
      end

      # Rough timing equalization: the fresh path pays one bcrypt hash.
      BCrypt::Password.create(SecureRandom.hex(12), cost: BCrypt::Engine.cost)

      cookies.signed[:registered_email] = {
        value: email,
        expires: 5.minutes.from_now,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }
      redirect_to registered_path
      return
    end

    @user = User.new(user_params)
    @user.locale = I18n.locale.to_s
    # ABA-003: one immutable request snapshot decides BOTH brand writes.
    # request.host, never effective_host - the RFC Forwarded header passes
    # nginx untouched and effective_host prefers it (see SiteBrand). Locale is
    # deliberately NOT brand: ?locale=fr on wetwijzer.be still registers
    # wetwijzer. An unregistered host stays nil - stored as NULL, "not
    # recorded" - and must never block the registration itself.
    registration_site_brand = SiteBrand.resolve_request(request)
    if registration_site_brand.nil?
      # Content-free by contract: no raw host, no identity. Production hosts
      # are all registered, so any hit here is worth investigating.
      Rails.logger.warn('[BRAND-ATTRIBUTION] registration on unresolved host; stored NULL')
    end
    @user.registration_brand = registration_site_brand

    # The account row, its starter credits and its 'registered' event commit
    # or vanish TOGETHER. Before this, save ran in its own transaction and
    # the credits in a second one; adding the activity as a third piece would
    # have let a half-registered account exist in three flavours. The
    # confirmation token/outbox flow stays deliberately OUTSIDE, exactly as
    # before: token+outbox are their own atomic pair, and synchronous email
    # must never run inside a database transaction.
    saved = AccountRecord.transaction do
      if @user.save
        # Grant starter credits for alpha testing (lets users try Level II/Level III/Level IV tiers)
        @user.add_credits!(STARTER_CREDITS)
        AccountActivity.log(@user, 'registered', request, site_brand: registration_site_brand)
        true
      else
        false
      end
    end

    if saved
      Rails.logger.info("[REGISTRATION] Granted #{STARTER_CREDITS} starter credits user_id=#{@user.id}")

      # FBL-032: with the durable-outbox flag on, the outbox row commits in
      # the same accounts transaction as the token, and the drain job owns
      # delivery with bounded retry. Flag off keeps the synchronous send.
      if EmailOutboxEntry.active_for_delivery?
        AccountRecord.transaction do
          @user.generate_confirmation_token!
          EmailOutboxEntry.enqueue!(@user, 'confirmation')
        end
      else
        @user.generate_confirmation_token!
        send_confirmation_email(@user)
      end
      Rails.logger.info("[REGISTRATION] New user registered: id=#{@user.id} from #{request.remote_ip}")

      # Keep registration state out of the CSRF-only Rails session.
      cookies.signed[:registered_email] = {
        value: @user.email,
        expires: 5.minutes.from_now,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }

      # If user selected Pro during registration, store intent for post-confirmation redirect
      if params[:plan] == 'pro'
        cookies.signed[:pending_pro] = {
          value: @user.email,
          expires: 7.days.from_now,
          httponly: true,
          secure: Rails.env.production?,
          same_site: :lax
        }
        # Billing interval is always monthly
        interval = 'monthly'
        cookies.signed[:pending_pro_interval] = {
          value: interval,
          expires: 7.days.from_now,
          httponly: true,
          secure: Rails.env.production?,
          same_site: :lax
        }
        Rails.logger.info("[REGISTRATION] Pro plan (#{interval}) selected user_id=#{@user.id} - will redirect to checkout after confirmation")
      end

      redirect_to registered_path
    else
      Rails.logger.info("[REGISTRATION] Failed registration attempt from #{request.remote_ip}: #{@user.errors.full_messages.join(', ')}")
      render :new, status: :unprocessable_entity
    end
  end

  def registered
    @registered_email = cookies.signed[:registered_email]
    cookies.delete(:registered_email) if @registered_email
    # If someone navigates here directly without registering, redirect to signup
    redirect_to signup_path unless @registered_email.present?
  end

  def confirm
    user = User.find_by(confirmation_token: params[:token])

    if user.nil?
      Rails.logger.warn("[CONFIRM] Token not found: #{params[:token]&.first(8)}...")
      redirect_to root_path, alert: t('auth.invalid_token')
    elsif user.confirmed?
      Rails.logger.info("[CONFIRM] Already-confirmed user_id=#{user.id}, redirecting to login")
      redirect_to login_path, notice: t('auth.email_confirmed')
    elsif user.confirmation_sent_at.nil? || user.confirmation_sent_at < 72.hours.ago
      Rails.logger.warn("[CONFIRM] Token expired user_id=#{user.id} (sent #{user.confirmation_sent_at})")
      redirect_to root_path, alert: t('auth.token_expired', default: t('auth.invalid_token'))
    else
      user.confirm!

      Rails.logger.info("[CONFIRM] Confirmed user_id=#{user.id}")
      redirect_to login_path, notice: t('auth.email_confirmed')
    end
  end

  def resend_confirmation
    # Support both logged-in users and unauthenticated users (from login page)
    user = current_user || User.find_by(email: params[:email]&.downcase)

    if user && !user.confirmed?
      # Rate limit: max 1 resend per 5 minutes per user
      if user.confirmation_sent_at && user.confirmation_sent_at > 5.minutes.ago
        redirect_to login_path, alert: t('auth.resend_too_soon')
        return
      end

      # FBL-032: same durable-outbox branch as the create path - token and
      # outbox row commit in one accounts transaction; the drain job owns
      # delivery. Flag off keeps the synchronous send.
      if EmailOutboxEntry.active_for_delivery?
        AccountRecord.transaction do
          user.generate_confirmation_token!
          EmailOutboxEntry.enqueue!(user, 'confirmation')
        end
      else
        user.generate_confirmation_token!
        send_confirmation_email(user)
      end
    end

    # Always show the same message (prevents email enumeration)
    redirect_to login_path, notice: t('auth.confirmation_resent')
  end

  private

  # deliver_now (not deliver_later: the :async adapter loses queued jobs on a
  # worker restart) with ONE bounded retry on TRANSIENT SMTP failures. A normal
  # send is ~3s; a Net::ReadTimeout is a transient Migadu blip that otherwise
  # silently loses the verification email. SMTP open/read timeouts (see
  # production.rb) keep the worst case well under the worker timeout.
  def send_confirmation_email(user)
    attempts = 0
    begin
      attempts += 1
      UserMailer.confirmation_email(user).deliver_now
      Rails.logger.info("[REGISTRATION] Confirmation email sent user_id=#{user.id}")
    rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError, IOError => e
      retry if attempts < 2
      Rails.logger.error("[REGISTRATION] Confirmation email FAILED (transient, #{attempts}x) user_id=#{user.id}: #{e.class}")
    rescue StandardError => e
      Rails.logger.error("[REGISTRATION] Failed to send confirmation email user_id=#{user.id}: #{e.class}")
    end
  end

  def require_production_environment
    return if Rails.env.production?

    redirect_to root_path, alert: 'Registration is disabled on this environment.'
  end

  def user_params
    params.require(:user).permit(:email, :password, :password_confirmation, :name, :terms_accepted)
  end

  def sign_in(user)
    token = user.generate_session_token!
    cookies.signed[:session_token] = {
      value: token,
      expires: 30.days.from_now,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
  end
end
