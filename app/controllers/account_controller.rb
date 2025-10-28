# frozen_string_literal: true

class AccountController < ApplicationController
  before_action :require_authentication

  def show
    @user = current_user
    @subscription = current_user.subscription
    @usage_stats = {
      total_queries: current_user.chatbot_usages.sum(:query_count),
      this_month: current_user.chatbot_usages.this_month.sum(:query_count)
    }
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
      if VALID_THEMES.include?(theme)
        current_user.update(theme_preference: theme)
      end
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
      user: {
        email: current_user.email,
        name: current_user.name,
        locale: current_user.locale,
        created_at: current_user.created_at,
        confirmed_at: current_user.confirmed_at
      },
      subscription: current_user.subscription&.slice(
        :tier, :status, :created_at, :current_period_start, :current_period_end
      ),
      usage: current_user.chatbot_usages.map do |u|
        { date: u.usage_date, queries: u.query_count }
      end
    }

    send_data data.to_json,
              filename: "wetwijzer-data-#{Date.current}.json",
              type: 'application/json'
  end

  def destroy
    # Cancel Stripe subscription if exists
    if current_user.subscription&.stripe_subscription_id.present?
      begin
        Stripe::Subscription.cancel(current_user.subscription.stripe_subscription_id)
      rescue Stripe::StripeError => e
        Rails.logger.error("Failed to cancel Stripe subscription: #{e.message}")
      end
    end

    # Clear session
    cookies.delete(:session_token)

    # Anonymize and delete user data
    current_user.chatbot_usages.delete_all
    current_user.subscription&.destroy
    current_user.destroy

    redirect_to root_path, notice: t('account.deleted')
  end

  private

  def billing_info_params
    params.permit(
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
