# frozen_string_literal: true

class RegistrationsController < ApplicationController
  # One-time credits granted to new accounts for alpha testing
  # Allows users to try higher-tier AI models (Level II/Level III/Level IV)
  STARTER_CREDITS = 5

  # CSRF protection is enabled (removed skip_before_action for security)
  before_action :require_production_environment, only: %i[new create]

  def new
    return unless registration_country_allowed!

    redirect_to root_path if current_user
    @user = User.new
  end

  def create
    return unless registration_country_allowed!
    return unless admit_registration!

    # Honeypot bot protection: reject if hidden field is filled
    if params[:website].present?
      SecurityLog.warn('registration_honeypot', request: request)
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
      SecurityLog.info('registration_duplicate', request: request)
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

      cookies.encrypted[:registered_email] = {
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
      SecurityLog.info('registration', request: request, user: @user)

      # Keep registration state out of the CSRF-only Rails session.
      cookies.encrypted[:registered_email] = {
        value: @user.email,
        expires: 5.minutes.from_now,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }

      # If user selected Pro during registration, store intent for post-confirmation redirect
      if params[:plan] == 'pro'
        # WW-PRIV-03: a flag, not the email; every reader only asks whether
        # it is present.
        cookies.signed[:pending_pro] = {
          value: true,
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
      # The attributes only: a message can repeat what was typed.
      SecurityLog.info('registration_failed', request: request, errors: @user.errors.attribute_names.join(','))
      # The network is still gated: the corrected form needs a new proof.
      @signup_challenge = @admission_policy.challenge if @admission.gated
      render :new, status: :unprocessable_entity
    end
  end

  # WW-PRIV-03: registered_email is an encrypted cookie; a signed one is
  # readable by whoever holds it.
  def registered
    @registered_email = cookies.encrypted[:registered_email]
    cookies.delete(:registered_email) if @registered_email
    # If someone navigates here directly without registering, redirect to signup
    redirect_to signup_path unless @registered_email.present?
  end

  def confirm
    user = User.find_by(confirmation_token: params[:token])

    if user.nil?
      Rails.logger.warn("[CONFIRM] Token not found: #{params[:token]&.first(8)}...")
      redirect_to root_path, alert: t('auth.invalid_token')
    elsif user.abuse_suspended?
      # WW-ABUSE-01: the same answer as an unknown token.
      Rails.logger.warn("[CONFIRM] Refused user_id=#{user.id}")
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

    # WW-ABUSE-01: nothing is minted or mailed for a suspended account; the
    # answer below stays the same.
    if user && !user.confirmed? && !user.abuse_suspended?
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

  # Run inside both actions so callback reordering cannot put account creation
  # ahead of this rule. Refuse before email lookup, counters, proofs or writes;
  # an existing login or a solved browsing challenge grants no exception.
  def registration_country_allowed!
    return true if RegistrationCountryPolicy.new(request: request).allowed?

    Rails.logger.info('[SIGNUP-COUNTRY] registration refused')
    response.headers['Cache-Control'] = 'private, no-store'
    respond_to do |format|
      format.html { render :country_restricted, status: :forbidden }
      format.json do
        render json: { error: 'registration_country_restricted',
                       message: t('auth.registration_country_restricted.message') }, status: :forbidden
      end
      format.any { head :forbidden }
    end
    false
  end

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

  # WW-ABUSE-01 (ABUSE-05): RegistrationAdmissionPolicy decides every
  # submission first, before the honeypot, as the limiter it replaced did. It
  # is called from create rather than declared as a callback, so tests that
  # re-add the production guard cannot reorder it. True when admitted;
  # otherwise the form is shown again with the non-secret fields only, and no
  # answer depends on whether the email has an account.
  def admit_registration!
    @admission_policy = RegistrationAdmissionPolicy.new(remote_ip: request.remote_ip,
                                                        email: submitted_registration_email)
    @admission = @admission_policy.evaluate(params[:signup_proof])
    return true if @admission.admitted?

    @user = User.new(retained_registration_params)
    case @admission.outcome
    when :challenge
      @signup_challenge = @admission_policy.challenge
      render :new, status: :unprocessable_entity
    when :unavailable
      flash.now[:alert] = t('auth.registration_unavailable')
      render :new, status: :service_unavailable
    else
      flash.now[:alert] = t('auth.too_many_attempts')
      render :new, status: :too_many_requests
    end
    false
  end

  def submitted_registration_email
    user = params[:user]
    user.is_a?(ActionController::Parameters) ? user[:email].to_s : ''
  end

  def retained_registration_params
    user = params[:user]
    user.is_a?(ActionController::Parameters) ? user.permit(:email, :name, :terms_accepted) : {}
  end

  def require_production_environment
    return if Rails.env.production?

    redirect_to root_path, alert: t('auth.registration_disabled_environment')
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
