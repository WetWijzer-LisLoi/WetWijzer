# frozen_string_literal: true

class ChatbotController < ApplicationController
  before_action :check_access
  before_action :check_usage_limit, only: [:ask]

  def index
    @language = params[:language] || I18n.locale.to_s
    @source = params[:source] || 'legislation'
    @use_local = params[:use_local] == '1'
    @queries_remaining = queries_remaining
  end

  def ask
    question = params[:question]&.strip
    @language = params[:language].presence || I18n.locale.to_s
    @source = params[:source].presence || 'legislation'
    @use_local = params[:use_local] == '1'

    if question.blank?
      @error = @language == 'fr' ? 'La question est obligatoire' : 'Vraag is verplicht'
      render :index and return
    end

    unless %w[nl fr].include?(@language)
      @language = 'nl'
    end

    source_sym = @source.to_sym
    unless %i[legislation jurisprudence all].include?(source_sym)
      source_sym = :legislation
    end

    service = if @use_local
                LocalChatbotService.new(language: @language)
              else
                LegalChatbotService.new(language: @language)
              end

    @result = service.ask(question, source: source_sym)

    # Track usage
    track_usage!

    @queries_remaining = queries_remaining
    render :index
  rescue StandardError => e
    Rails.logger.error("Chatbot error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    @error = @language == 'fr' ? "Erreur: #{e.message}" : "Fout: #{e.message}"
    render :index
  end

  private

  def check_access
    # Legacy passphrase access (admin/testing)
    passphrase = ENV['CHATBOT_PASSPHRASE']
    if passphrase.present? && params[:pass].present? && ActiveSupport::SecurityUtils.secure_compare(params[:pass].to_s, passphrase)
      @passphrase_valid = true
      return true # Valid passphrase - allow access
    end

    # Require authentication - no anonymous access
    unless current_user || @passphrase_valid
      if request.format.html?
        redirect_to login_path, alert: t('auth.login_required')
      else
        render json: { error: t('auth.login_required') }, status: :unauthorized
      end
      return
    end

    # Check if user can use chatbot (active account + within limits)
    # Skip this check if passphrase is valid
    return true if @passphrase_valid
    unless current_user&.can_use_chatbot?
      if request.format.html?
        redirect_to pricing_path, alert: t('chatbot.limit_exceeded')
      else
        render json: { error: t('chatbot.limit_exceeded') }, status: :payment_required
      end
    end
  end

  def check_usage_limit
    return if params[:pass].present? # Legacy passphrase bypasses limits
    return unless current_user

    source = (params[:source].presence || 'legislation').to_sym
    credit_cost = current_user.credit_cost_for(source)

    # Check if user can access the requested source
    unless current_user.can_access_source?(source)
      @error = case source
               when :jurisprudence
                 t('chatbot.jurisprudence_paid_only')
               when :parliamentary
                 t('chatbot.parliamentary_paid_only')
               else
                 t('chatbot.insufficient_credits', cost: credit_cost)
               end
      @credits_remaining = current_user.credits
      @credit_cost = credit_cost
      render :index and return
    end

    # Check if user has enough credits
    unless current_user.has_credits?(credit_cost)
      @error = t('chatbot.insufficient_credits', cost: credit_cost, balance: current_user.credits)
      @credits_remaining = current_user.credits
      @credit_cost = credit_cost
      render :index and return
    end
  end

  def track_usage!
    return unless current_user
    return if params[:pass].present? # Passphrase users don't consume credits

    source = (params[:source].presence || 'legislation').to_sym
    current_user.use_credits_for_question!(source)
  end

  def queries_remaining
    return nil unless current_user
    current_user.credits
  end
end
