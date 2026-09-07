# frozen_string_literal: true

class AccountController < ApplicationController
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
  end

  def update
    @user = current_user

    if params[:password].present?
      unless @user.authenticate(params[:current_password])
        flash.now[:alert] = t('account.wrong_password')
        render :edit, status: :unprocessable_entity
        return
      end

      @user.password = params[:password]
      @user.password_confirmation = params[:password_confirmation]
    end

    @user.name = params[:name] if params[:name].present?

    # Invoice language preference
    if params[:invoice_locale].present?
      locale = params[:invoice_locale].to_s.strip
      @user.invoice_locale = %w[nl fr de en].include?(locale) ? locale : nil
    elsif params.key?(:invoice_locale) && params[:invoice_locale].blank?
      @user.invoice_locale = nil # Reset to auto-detect
    end

    if @user.save
      redirect_to account_path, notice: t('account.updated')
    else
      flash.now[:alert] = @user.errors.full_messages.join(', ')
      render :edit, status: :unprocessable_entity
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
    @subscription = current_user.subscription
  end

  def update_billing_info
    @subscription = current_user.subscription

    unless @subscription
      redirect_to account_path, alert: t('account.no_subscription')
      return
    end

    if @subscription.update(billing_info_params)
      redirect_to account_path, notice: t('account.billing_info_updated')
    else
      flash.now[:alert] = @subscription.errors.full_messages.join(', ')
      render :billing_info, status: :unprocessable_entity
    end
  end

  def export_data
    # FBL-031: the envelope is built by the versioned AccountExportService.
    # The inline predecessor silently exported an empty usage section (it
    # asked ChatbotAnalytic for columns that never existed and rescued the
    # error away) and crashed on credit purchases (:credits is not a column).
    data = AccountExportService.call(current_user)

    # ISO 27001 A.8.12 - audit trail records THAT an export happened, never
    # its contents.
    AccountActivity.log(current_user, 'data_exported', request)

    send_data data.to_json,
              filename: "wetwijzer-data-#{Date.current}.json",
              type: 'application/json'
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
    current_user.update!(
      deletion_scheduled_for: nil,
      deletion_reason: nil,
      active: true
    )
    redirect_to account_path, notice: t('account.deletion_cancelled'), status: :see_other
  end

  private

  def billing_info_params
    params.permit(
      :customer_type,
      :vat_number,
      :company_name,
      :enterprise_number,
      :billing_address_line1,
      :billing_address_line2,
      :billing_city,
      :billing_postal_code,
      :billing_country
    )
  end
end
