# frozen_string_literal: true

module Api
  class ChatbotController < ApplicationController
    # Skip CSRF for API endpoint (use API key authentication in production)
    # Note: This is acceptable for a stateless API with no session cookies.
    # Rate limiting provides DoS protection.
    skip_forgery_protection
    
    # Rate limiting: disabled for testing
    before_action :check_access
    # before_action :rate_limit_check
    before_action :set_request_id_in_thread
    
    # POST /api/chatbot/ask (or GET for SSE streaming)
    # Params: { question: "...", language: "nl", source: "legislation|jurisprudence|all", stream: true/false, conversation_id: "..." }
    # 
    # Source options:
    # - "legislation" (default): Fast (~15-30s), searches written law only
    # - "jurisprudence": Fast (~15-30s), searches case law/court rulings only  
    # - "all": Comprehensive (~30-50s), searches both sources - slower but more complete
    #
    # Conversation support:
    # - First question: don't send conversation_id, response includes new conversation_id
    # - Follow-up questions: send conversation_id to maintain context
    def ask
      question = params[:question]&.strip
      language = params[:language] || 'nl'
      source_param = params[:source] || 'legislation'
      source = source_param.to_s.to_sym
      stream = params[:stream] == 'true' || params[:stream] == true
      conversation_id = params[:conversation_id]&.strip

      # Validation
      if question.blank?
        return render json: { error: 'Question is required' }, status: :bad_request
      end

      unless %w[nl fr].include?(language)
        return render json: { error: 'Language must be nl or fr' }, status: :bad_request
      end

      unless %i[legislation jurisprudence all].include?(source)
        return render json: { 
          error: 'Source must be: legislation (fast), jurisprudence (fast), or all (slow but comprehensive)' 
        }, status: :bad_request
      end

      # Get or create conversation for context
      conversation = find_or_create_conversation(conversation_id, language)

      if stream
        # Stream with progress updates
        response.headers['Content-Type'] = 'text/event-stream'
        response.headers['Cache-Control'] = 'no-cache'
        response.headers['X-Accel-Buffering'] = 'no'
        
        begin
          chatbot = LegalChatbotService.new(language: language, conversation: conversation)
          
          # Define progress callback
          progress_callback = ->(percent, message) {
            response.stream.write("data: #{JSON.generate({ type: 'progress', percent: percent, message: message })}\n\n")
          }
          
          # Process with progress
          result = if source == :legislation
            chatbot.search_legislation(question, progress_callback: progress_callback)
          else
            chatbot.ask(question, source: source)
          end
          
          # Save to conversation and add conversation_id to result
          save_to_conversation(conversation, question, result)
          result[:conversation_id] = conversation.token
          
          # Send final result
          response.stream.write("data: #{JSON.generate({ type: 'result', data: result })}\n\n")
          
          log_chatbot_request(question, result, language)
        ensure
          response.stream.close
        end
      else
        # Standard JSON response
        chatbot = LegalChatbotService.new(language: language, conversation: conversation)
        result = chatbot.ask(question, source: source)
        
        # Save to conversation and add conversation_id to result
        save_to_conversation(conversation, question, result)
        result[:conversation_id] = conversation.token
        
        log_chatbot_request(question, result, language)
        
        if result[:error]
          render json: result, status: :service_unavailable
        else
          render json: result
        end
      end
    rescue ArgumentError => e
      render json: { error: e.message }, status: :bad_request
    rescue StandardError => e
      Rails.logger.error("Chatbot controller error: #{e.message}")
      render json: { error: 'Internal server error' }, status: :internal_server_error
    end
    
    # GET /api/chatbot/health
    # Health check endpoint
    def health
      render json: { 
        status: 'ok',
        version: '1.0',
        embeddings_count: Article.where.not(embedding: nil).count
      }
    end
    
    private
    
    def set_request_id_in_thread
      Thread.current[:request_id] = request.request_id
    end
    
    def rate_limit_check
      # Use IP address as key
      key = "chatbot_rate_limit:#{request.remote_ip}"
      
      # Check current count
      count = Rails.cache.read(key) || 0
      
      if count >= 100
        render json: { 
          error: 'Rate limit exceeded. Maximum 100 requests per hour.' 
        }, status: :too_many_requests
        return
      end
      
      # Increment counter
      Rails.cache.write(key, count + 1, expires_in: 1.hour)
    end
    
    def check_access
      passphrase = ENV.fetch('CHATBOT_PASSPHRASE', 'o6PctYY0oI2fGPISpNcIgW7vpkmo5UxKpoHr2C2uZDX6v6Xmlv_U7vghmlIRHiXn')
      provided = params[:pass].to_s
      
      Rails.logger.info("API Chatbot check_access: provided=#{provided[0..5]}... expected=#{passphrase[0..5]}...")
      
      unless ActiveSupport::SecurityUtils.secure_compare(provided, passphrase)
        Rails.logger.warn("API Chatbot access denied from IP: #{request.remote_ip}, params: #{params.keys}")
        render json: { error: 'Access denied' }, status: :forbidden
        return false
      end
      true
    end
    
    def log_chatbot_request(question, response, language)
      # Simple logging to Rails logger
      # In production, consider using a dedicated analytics table
    
      # Sanitize question to prevent log injection attacks
      safe_question = question.gsub(/[\n\r\t\x00-\x1f\x7f]/, ' ')
      
      Rails.logger.info({
        event: 'chatbot_question',
        question: safe_question,
        language: language,
        sources_count: response[:sources]&.length || 0,
        response_time: response[:response_time],
        has_error: response[:error].present?,
        ip: request.remote_ip,
        request_id: request.request_id,
        timestamp: Time.current
      }.to_json)
    end

    def find_or_create_conversation(conversation_id, language)
      ChatbotConversation.ensure_table_exists
      
      if conversation_id.present?
        conv = ChatbotConversation.find_by(token: conversation_id)
        if conv && !conv.expired?
          conv.extend_expiry!
          return conv
        end
      end
      
      # Create new conversation
      ChatbotConversation.create!(language: language)
    end

    def save_to_conversation(conversation, question, result)
      return unless conversation && result

      # Extract NUMACs from sources
      numacs = result[:sources]&.map { |s| s[:numac] }&.compact || []
      
      # Add user question
      conversation.add_message(role: 'user', content: question, numacs: numacs)
      
      # Add assistant answer
      conversation.add_message(role: 'assistant', content: result[:answer]) if result[:answer]
    end
  end
end
