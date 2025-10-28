# frozen_string_literal: true

class ChatbotController < ApplicationController
  before_action :check_access

  def index
    @language = params[:language] || I18n.locale.to_s
    @source = params[:source] || 'legislation'
    @use_local = params[:use_local] == '1'
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

    render :index
  rescue StandardError => e
    Rails.logger.error("Chatbot error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    @error = @language == 'fr' ? "Erreur: #{e.message}" : "Fout: #{e.message}"
    render :index
  end

  private

  def check_access
    client_ip = request.remote_ip
    
    # Passphrase protection with timing-attack safe comparison
    passphrase = ENV.fetch('CHATBOT_PASSPHRASE', 'o6PctYY0oI2fGPISpNcIgW7vpkmo5UxKpoHr2C2uZDX6v6Xmlv_U7vghmlIRHiXn')
    
    unless ActiveSupport::SecurityUtils.secure_compare(params[:pass].to_s, passphrase)
      Rails.logger.warn("Chatbot access denied - invalid passphrase from IP: #{client_ip}")
      render plain: 'Access denied.', status: :forbidden
    end
  end
end
