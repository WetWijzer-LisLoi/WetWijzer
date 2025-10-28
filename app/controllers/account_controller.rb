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

  VALID_THEMES = %w[original blue purple green amber red pink teal].freeze

  def update_preferences
    if params[:theme_preference].present?
      theme = params[:theme_preference].to_s.downcase.strip
      current_user.update(theme_preference: theme) if VALID_THEMES.include?(theme)
    end
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

  def billing_portal
    subscription = current_user.subscription

    unless subscription&.stripe_customer_id.present?
      redirect_to subscription_path, alert: t('subscriptions.no_billing_info')
      return
    end

    session = Stripe::BillingPortal::Session.create(
      customer: subscription.stripe_customer_id,
      return_url: account_url
    )

    redirect_to session.url, allow_other_host: true
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe Portal error: #{e.message}")
    redirect_to account_path, alert: t('subscriptions.portal_error')
  end

  def export_data
    data = {
      exported_at: Time.current.iso8601,
      user: {
        email: current_user.email,
        name: current_user.name,
        locale: current_user.locale,
        created_at: current_user.created_at,
        confirmed_at: current_user.confirmed_at,
        credits: current_user.credits,
        theme_preference: current_user.theme_preference
      },
      subscription: current_user.subscription&.slice(
        :tier, :status, :created_at, :current_period_start, :current_period_end
      ),
      credit_purchases: current_user.credit_purchases.order(:created_at).map do |cp|
        cp.slice(:package, :credits, :amount_cents, :currency, :payment_method, :created_at)
      end,
      saved_answers: current_user.saved_answers.order(:created_at).map do |sa|
        { question: sa.question, answer: sa.answer, category: sa.category, sources: sa.sources, created_at: sa.created_at }
      end,
      usage: begin
        ChatbotAnalytic.where(user_id: current_user.id)
                       .order(:created_at)
                       .pluck(:created_at, :model_tier, :source_type, :credits_used)
                       .map { |ts, tier, src, cr| { timestamp: ts, model_tier: tier, source: src, credits: cr } }
      rescue StandardError => e
        Rails.logger.warn("[Account] Query failed: #{e.message}")
        []
      end,
      activity_log: current_user.account_activities.order(:created_at).map do |a|
        a.slice(:activity_type, :ip_address, :user_agent, :created_at)
      end
    }

    # ISO 27001 A.8.12 - audit trail for data exports (data leakage prevention)
    AccountActivity.log(current_user, 'data_exported', request)

    send_data data.to_json,
              filename: "wetwijzer-data-#{Date.current}.json",
              type: 'application/json'
  end

  def destroy
    # Schedule account for deletion (30-day grace period)
    current_user.update!(
      deletion_scheduled_for: 30.days.from_now,
      deletion_reason: 'user_requested',
      active: false
    )

    # Send confirmation email
    UserMailer.deletion_scheduled(current_user).deliver_later

    # Clear session
    cookies.delete(:session_token)

    redirect_to root_path, notice: t('account.deletion_scheduled_notice'), status: :see_other
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
