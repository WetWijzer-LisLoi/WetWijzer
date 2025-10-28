# frozen_string_literal: true

module Api
  # API controller for managing search alerts
  # Allows users to subscribe to search queries and receive email notifications
  class SearchAlertsController < ApplicationController
    skip_before_action :verify_authenticity_token, only: [:create]
    
    # POST /api/search_alerts
    # Creates a new search alert subscription
    #
    # @param email [String] Email address for notifications
    # @param query [String] Search query to monitor
    # @param filters [Hash] Optional search filters
    # @param frequency [String] 'daily' or 'weekly'
    #
    # @return [JSON] Success/error response
    def create
      @alert = SearchAlert.new(alert_params)
      
      if @alert.save
        # Send confirmation email
        SearchAlertMailer.confirmation(@alert).deliver_later
        
        render json: {
          success: true,
          message: I18n.t('search_alerts.confirmation_sent')
        }, status: :created
      else
        render json: {
          success: false,
          errors: @alert.errors.full_messages
        }, status: :unprocessable_entity
      end
    end

    # GET /api/search_alerts/confirm/:token
    # Confirms a search alert subscription
    def confirm
      @alert = SearchAlert.find_by(confirmation_token: params[:token])
      
      if @alert
        @alert.confirm!
        redirect_to root_path, notice: I18n.t('search_alerts.confirmed')
      else
        redirect_to root_path, alert: I18n.t('search_alerts.invalid_token')
      end
    end

    # DELETE /api/search_alerts/unsubscribe/:token
    # Unsubscribes from a search alert
    def unsubscribe
      @alert = SearchAlert.find_by(unsubscribe_token: params[:token])
      
      if @alert
        @alert.unsubscribe!
        
        respond_to do |format|
          format.html { redirect_to root_path, notice: I18n.t('search_alerts.unsubscribed') }
          format.json { render json: { success: true, message: I18n.t('search_alerts.unsubscribed') } }
        end
      else
        respond_to do |format|
          format.html { redirect_to root_path, alert: I18n.t('search_alerts.invalid_token') }
          format.json { render json: { success: false, error: I18n.t('search_alerts.invalid_token') }, status: :not_found }
        end
      end
    end

    private

    def alert_params
      params.permit(:email, :query, :frequency, filters: {})
    end
  end
end
