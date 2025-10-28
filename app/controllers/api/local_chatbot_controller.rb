# frozen_string_literal: true

module Api
  class LocalChatbotController < ApplicationController
    # Skip CSRF for API endpoint (acceptable for stateless API)
    skip_forgery_protection
    before_action :rate_limit_check
    before_action :set_request_id_in_thread
    
    # POST /api/local_chatbot/ask
    # Params: { question: "...", language: "nl", source: "legislation" }
    def ask
      question = params[:question]&.strip
      language = params[:language] || 'nl'
      source = params[:source]&.to_sym || :legislation

      if question.blank?
        return render json: { error: 'Question is required' }, status: :bad_request
      end

      unless %w[nl fr].include?(language)
        return render json: { error: 'Language must be nl or fr' }, status: :bad_request
      end

      unless %i[legislation jurisprudence all].include?(source)
        return render json: { error: 'Source must be legislation, jurisprudence, or all' }, status: :bad_request
      end

      # Use local service
      chatbot = LocalChatbotService.new(language: language)
      response = chatbot.ask(question, source: source)
      
      log_chatbot_request(question, response, language)
      
      if response[:error]
        render json: response, status: :service_unavailable
      else
        render json: response
      end
    rescue ArgumentError => e
      render json: { error: e.message }, status: :bad_request
    rescue StandardError => e
      Rails.logger.error("Local chatbot controller error: #{e.message}")
      render json: { error: 'Internal server error' }, status: :internal_server_error
    end
    
    # GET /api/local_chatbot/health
    def health
      ollama_status = begin
        uri = URI('http://localhost:11434/api/tags')
        response = Net::HTTP.get_response(uri)
        response.is_a?(Net::HTTPSuccess) ? 'running' : 'stopped'
      rescue StandardError
        'not installed'
      end
      
      render json: { 
        status: 'ok',
        version: '1.0 (local)',
        ollama: ollama_status,
        model: LocalChatbotService::MODEL,
        articles_count: Article.count
      }
    end
    
    private
    
    def set_request_id_in_thread
      Thread.current[:request_id] = request.request_id
    end
  
    def rate_limit_check
      key = "local_chatbot_rate_limit:#{request.remote_ip}"
      count = Rails.cache.read(key) || 0
      
      if count >= 20 # More generous for local
        render json: { 
          error: 'Rate limit exceeded. Maximum 20 requests per hour.' 
        }, status: :too_many_requests
        return
      end
      
      Rails.cache.write(key, count + 1, expires_in: 1.hour)
    end
    
    def log_chatbot_request(question, response, language)
      # JSON encoding automatically escapes special characters, making it safe
      # But also sanitize newlines/control chars just in case
      safe_question = question.gsub(/[\n\r\t\x00-\x1f\x7f]/, ' ')
      
      Rails.logger.info({
        event: 'local_chatbot_question',
        question: safe_question,
        language: language,
        sources_count: response[:sources]&.length || 0,
        response_time: response[:response_time],
        model: response[:model],
        has_error: response[:error].present?,
        ip: request.remote_ip,
        request_id: request.request_id,
        timestamp: Time.current
      }.to_json)
    end
  end
end
