# frozen_string_literal: true

class AccountController < ApplicationController
  include SuccessfulSignIn
  include AuthRateLimiting

  before_action :require_authentication

  def show
    @user = current_user
    @subscription = current_user.subscription
    @usage_stats = begin
      {
        total_queries: ChatbotAnalytic.where(user_id: current_user.id).count,
        this_month: ChatbotAnalytic.where(user_id: current_user.id)
                                   .where('created_at >= ?', Date.current.beginning_of_month).count
      }
    rescue StandardError => e
      Rails.logger.warn("[Account] Query failed: #{e.message}")
      { total_queries: 0, this_month: 0 }
    end
  end

  def edit
    @user = current_user
    @subscription = billing_subscription
  end

  def update
    @user = current_user
    @subscription = billing_subscription
    password_changed = false

    unless %i[password current_password password_confirmation name invoice_locale default_portal].all? { |key| !params.key?(key) || params[key].is_a?(String) }
      flash.now[:alert] = t('billing_profile.invalid_profile')
      render :edit, formats: [:html], status: :unprocessable_entity
      return
    end

    if (params.key?(:invoice_locale) && !['', 'nl', 'fr', 'de', 'en'].include?(params[:invoice_locale].strip)) ||
       (params.key?(:default_portal) && !([''] + SiteBrand::KEYS).include?(params[:default_portal].strip))
      flash.now[:alert] = t('billing_profile.invalid_profile')
      render :edit, formats: [:html], status: :unprocessable_entity
      return
    end

    if params[:password].present?
      unless params[:password].is_a?(String) && params[:current_password].is_a?(String) &&
             params[:password_confirmation].is_a?(String)
        flash.now[:alert] = t('account.wrong_password')
        render :edit, formats: [:html], status: :unprocessable_entity
        return
      end
      # Reserve before the expensive password check, including successful checks.
      if attempt_limited?('auth:account-current-password:ip', request.remote_ip, limit: 10, window: 15.minutes) ||
         attempt_limited?('auth:account-current-password:user', current_user.id, limit: 10, window: 15.minutes)
        flash.now[:alert] = t('auth.too_many_attempts')
        render :edit, formats: [:html], status: :too_many_requests
        return
      end
      unless @user.authenticate(params[:current_password])
        flash.now[:alert] = t('account.wrong_password')
        render :edit, formats: [:html], status: :unprocessable_entity
        return
      end

      @user.password = params[:password]
      @user.password_confirmation = params[:password_confirmation]
      # WW-SEC-03: the new token is written in the same UPDATE as the new
      # password, so every other device's cookie dies with the old one.
      rotated_session_token = SecureRandom.urlsafe_base64(32)
      @user.session_token = rotated_session_token
      password_changed = true
    end

    if params.key?(:name)
      unless params[:name].is_a?(String)
        flash.now[:alert] = t('billing_profile.invalid_profile')
        render :edit, formats: [:html], status: :unprocessable_entity
        return
      end
      name = params[:name].strip
      if name.length > 100 || name.match?(/[\u0000-\u001F\u007F]/)
        flash.now[:alert] = t('billing_profile.invalid_profile')
        render :edit, formats: [:html], status: :unprocessable_entity
        return
      end
      @user.name = name.presence
    end

    # Invoice language preference
    if params[:invoice_locale].present?
      locale = params[:invoice_locale].to_s.strip
      @user.invoice_locale = %w[nl fr de en].include?(locale) ? locale : nil
    elsif params.key?(:invoice_locale) && params[:invoice_locale].blank?
      @user.invoice_locale = nil # Reset to auto-detect
    end

    # The reader's default portal: which of our four sites is theirs. Decides
    # which brand writes to them and where the links in that mail lead.
    #
    # Blank means "follow where I registered", and that default is stored by
    # REMOVING the key rather than by writing today's answer into every row.
    # A stored value would freeze the default at the moment the reader last
    # opened this page; an absent key lets BrandMailerIdentity keep deciding.
    if params.key?(:default_portal)
      choice = params[:default_portal].to_s.strip
      preferences = @user.ui_prefs
      if SiteBrand::KEYS.include?(choice)
        preferences[BrandMailerIdentity::PREFERENCE_KEY] = choice
      else
        preferences.delete(BrandMailerIdentity::PREFERENCE_KEY)
      end
      @user.ui_prefs = preferences
    end

    profile_changed = @user.changed.intersect?(%w[name invoice_locale ui_preferences])
    if @user.save
      # This device stays signed in, for the short lifetime: the cookie does
      # not record whether "remember me" was chosen, and a longer one would
      # extend a session the reader never asked to keep.
      write_session_cookie!(rotated_session_token, remember: false) if rotated_session_token
      safely_log_account_activity('password_changed') if password_changed
      safely_log_account_activity('profile_updated') if profile_changed
      redirect_to account_path, notice: t('account.updated')
    else
      flash.now[:alert] = @user.errors.full_messages.join(', ')
      render :edit, formats: [:html], status: :unprocessable_entity
    end
  end

  VALID_COLOR_MODES = %w[light dark system].freeze
  VALID_ACCENT_THEMES = %w[original blue purple green amber red pink teal].freeze

  def update_preferences
    updates = {}
    color_mode = params.dig(:preferences, :theme)
    accent_theme = params[:theme_preference]

    if color_mode.present?
      color_mode = color_mode.to_s.downcase.strip
      return head :unprocessable_entity unless VALID_COLOR_MODES.include?(color_mode)

      updates['theme'] = color_mode
    end

    if accent_theme.present?
      accent_theme = accent_theme.to_s.downcase.strip
      return head :unprocessable_entity unless VALID_ACCENT_THEMES.include?(accent_theme)

      updates['theme_accent'] = accent_theme
    end

    return head :bad_request if updates.empty?

    current_user.merge_ui_prefs!(updates)
    head :ok
  end

  def activity_log
    @activities = current_user.account_activities.recent
  end

  def billing_info
    @subscription = billing_subscription
  end

  def update_billing_info
    @subscription = current_user.subscription || current_user.build_subscription(tier: 'free', status: 'incomplete')
    unless valid_billing_parameters?
      flash.now[:alert] = t('billing_profile.invalid_details')
      render :billing_info, formats: [:html], status: :unprocessable_entity
      return
    end
    @subscription.assign_attributes(billing_info_params)
    @subscription.assign_attributes(company_name: nil, vat_number: nil, enterprise_number: nil) if params[:customer_type] == 'consumer'

    if @subscription.save
      safely_log_account_activity('profile_updated')
      redirect_to account_path, notice: t('account.billing_info_updated')
    else
      flash.now[:alert] = @subscription.errors.full_messages.join(', ')
      render :billing_info, formats: [:html], status: :unprocessable_entity
    end
  end

  def export_data
    account_id = current_user.id
    # Retain only the existing audit fields, not a controller/request closure.
    audit_request = Struct.new(:remote_ip, :user_agent).new(request.remote_ip, request.user_agent)
    completed = lambda do
      AccountRecord.connection_pool.with_connection do
        account = User.find_by(id: account_id)
        AccountActivity.log(account, 'data_exported', audit_request) if account
      end
    rescue StandardError => e
      # A concurrent erasure/audit outage must not resurrect an account or
      # corrupt an otherwise complete download. Never log payload/error text.
      Rails.logger.error("[AccountExport] audit_failed #{e.class}")
    end
    body = AccountExportDownload.prepare(current_user, on_complete: completed)
    send_file_headers!(filename: "wetwijzer-data-#{Date.current}.json", type: 'application/json')
    response.headers['Content-Length'] = body.bytesize.to_s
    self.response_body = body
  rescue StandardError => e
    body&.close
    Rails.logger.error("[AccountExport] generation_failed #{e.class}")
    response.headers.delete('Content-Disposition')
    response.headers.delete('Content-Transfer-Encoding')
    response.headers.delete('Content-Length')
    head :service_unavailable
  ensure
    # Download headers/middleware must never downgrade the authenticated
    # response to merely revalidatable. Apply after send_file_headers!, on
    # failure too, and preserve any existing negotiated Vary dimensions.
    response.cache_control.clear
    response.cache_control[:private] = true
    response.cache_control[:no_store] = true
    response.headers['Cache-Control'] = 'private, no-store'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    vary = response.headers['Vary'].to_s.split(',').map(&:strip).reject(&:empty?)
    response.headers['Vary'] = (vary + ['Cookie']).join(', ') unless vary.any? { |header| header.casecmp?('Cookie') || header == '*' }
  end

  def destroy
    # Cancel recurring billing before disabling the account. This call also
    # fences a queued Mollie provision job, so a first payment cannot create a
    # hidden recurring subscription during the 30-day deletion grace period.
    subscription = current_user.subscription
    MollieSubscriptionCancellationService.new(subscription).cancel! if subscription

    # Fence checkout creation and verify there is no accepted payment whose
    # outcome still needs the account. Mollie intent creation obtains the same
    # SQLite write lock, so a concurrent checkout cannot slip between this
    # check and the account fence.
    AccountRecord.transaction do
      current_user.lock!
      current_user.update!(
        deletion_scheduled_for: 30.days.from_now,
        deletion_reason: 'user_requested',
        active: false,
        session_token: nil
      )
      AccountErasureService.ensure_financial_work_settled!(current_user)
    end

    # Send confirmation email
    UserMailer.deletion_scheduled(current_user).deliver_later

    # Clear session
    cookies.delete(:session_token)

    redirect_to root_path, notice: t('account.deletion_scheduled_notice'), status: :see_other
  rescue MollieSubscriptionCancellationService::CancellationError => e
    Rails.logger.error("[Account] Remote billing cancellation failed before deletion: #{e.class}")
    redirect_to account_path,
                alert: t(
                  'account.deletion_billing_cancellation_failed',
                  default: 'Your account was not scheduled for deletion because recurring billing could not be stopped safely. Please try again or contact support.'
                ),
                status: :see_other
  rescue AccountErasureService::PendingFinancialWork => e
    Rails.logger.warn("[Account] Account deletion deferred for pending financial work: #{e.class}")
    redirect_to account_path,
                alert: t(
                  'account.deletion_payment_pending',
                  default: 'Your account was not scheduled for deletion because a payment is still being processed. Please try again after it finishes or contact support.'
                ),
                status: :see_other
  end

  def cancel_deletion
    # WW-ABUSE-01: a suspended account keeps no session and never gets here;
    # refused anyway, so no ordinary path writes active=true for one.
    unless current_user.activatable?
      redirect_to account_path, alert: t('auth.access_unavailable'), status: :see_other
      return
    end

    current_user.update!(
      deletion_scheduled_for: nil,
      deletion_reason: nil,
      active: true
    )
    redirect_to account_path, notice: t('account.deletion_cancelled'), status: :see_other
  end

  private

  BILLING_FIELDS = %i[
    customer_type vat_number company_name enterprise_number billing_address_line1
    billing_address_line2 billing_city billing_postal_code billing_country
  ].freeze

  def billing_info_params
    params.permit(*BILLING_FIELDS)
  end

  def billing_subscription
    current_user.subscription || current_user.build_subscription(tier: 'free', status: 'incomplete')
  end

  def valid_billing_parameters?
    # Validate the raw shape before strong parameters can silently drop an
    # array/hash in a scalar field and turn an invalid update into success.
    BILLING_FIELDS.each do |key|
      next unless params.key?(key)

      value = params[key]
      return false unless value.is_a?(String) && value.length <= 255 && !value.match?(/[\u0000-\u001F\u007F]/)
    end
    true
  end

  def safely_log_account_activity(action)
    AccountActivity.log(current_user, action, request)
  rescue StandardError => e
    Rails.logger.warn("[Account] activity_log_failed #{e.class}")
  end
end
