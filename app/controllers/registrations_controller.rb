# frozen_string_literal: true

class RegistrationsController < ApplicationController
  include AuthRateLimiting

  # One-time credits granted to new accounts for alpha testing
  # Allows users to try higher-tier AI models (Genius/Mastermind/Omniscient)
  STARTER_CREDITS = 10

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

    # Block registration if account already exists
    existing_user = User.find_by(email: email)
    if existing_user
      Rails.logger.info("[REGISTRATION] Duplicate registration attempt for #{email} from #{request.remote_ip}")
      # Still alert the existing account owner (security)
      UserMailer.security_alert(
        existing_user,
        'registration_attempt',
        { ip: request.remote_ip, user_agent: request.user_agent }
      ).deliver_later

      @user = User.new(user_params)
      login_link = ActionController::Base.helpers.link_to(
        t('auth.login'), login_path,
        class: 'font-medium text-blue-600 dark:text-blue-400 hover:underline'
      )
      reset_link = ActionController::Base.helpers.link_to(
        case I18n.locale
        when :fr then 'réinitialiser votre mot de passe'
        when :de then 'Ihr Passwort zurücksetzen'
        when :en then 'reset your password'
        else 'uw wachtwoord resetten'
        end,
        new_password_reset_path,
        class: 'font-medium text-blue-600 dark:text-blue-400 hover:underline'
      )
      error_msg = case I18n.locale
                  when :fr
                    "Cette adresse e-mail est déjà enregistrée. Vous pouvez #{login_link} ou #{reset_link}."
                  when :de
                    "Diese E-Mail-Adresse ist bereits registriert. Sie können sich #{login_link} oder #{reset_link}."
                  when :en
                    "This email address is already registered. You can #{login_link} or #{reset_link}."
                  else
                    "Dit e-mailadres is al geregistreerd. U kunt #{login_link} of #{reset_link}."
                  end
      @user.errors.add(:base, error_msg)
      render :new, status: :unprocessable_entity
      return
    end

    @user = User.new(user_params)
    @user.locale = I18n.locale.to_s

    if @user.save
      # Grant starter credits for alpha testing (lets users try Genius/Mastermind/Omniscient tiers)
      @user.add_credits!(STARTER_CREDITS)
      Rails.logger.info("[REGISTRATION] Granted #{STARTER_CREDITS} starter credits to #{@user.email}")

      # Send confirmation email synchronously (deliver_now, not deliver_later)
      # deliver_later silently fails with default :async adapter on worker restarts
      @user.generate_confirmation_token!
      begin
        UserMailer.confirmation_email(@user).deliver_now
        Rails.logger.info("[REGISTRATION] Confirmation email sent to #{@user.email}")
      rescue StandardError => e
        Rails.logger.error("[REGISTRATION] Failed to send confirmation email to #{@user.email}: #{e.message}")
      end
      Rails.logger.info("[REGISTRATION] New user registered: #{@user.email} from #{request.remote_ip}")

      # Store email in signed cookie for confirmation page (sessions are disabled)
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
        Rails.logger.info("[REGISTRATION] Pro plan selected by #{@user.email} — will redirect to checkout after confirmation")
      end

      redirect_to registered_path
    else
      Rails.logger.info("[REGISTRATION] Failed registration attempt for #{email} from #{request.remote_ip}: #{@user.errors.full_messages.join(', ')}")
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
      Rails.logger.info("[CONFIRM] User #{user.email} already confirmed, redirecting to login")
      redirect_to login_path, notice: t('auth.email_confirmed')
    elsif user.confirmation_sent_at.nil? || user.confirmation_sent_at < 72.hours.ago
      Rails.logger.warn("[CONFIRM] Token expired for #{user.email} (sent #{user.confirmation_sent_at})")
      redirect_to root_path, alert: t('auth.token_expired', default: t('auth.invalid_token'))
    else
      user.confirm!
      user.record_activity!(:email_confirmed, request) if user.respond_to?(:record_activity!)
      Rails.logger.info("[CONFIRM] User #{user.email} confirmed successfully")
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

      user.generate_confirmation_token!
      UserMailer.confirmation_email(user).deliver_now
    end

    # Always show the same message (prevents email enumeration)
    redirect_to login_path, notice: t('auth.confirmation_resent')
  end

  private

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
