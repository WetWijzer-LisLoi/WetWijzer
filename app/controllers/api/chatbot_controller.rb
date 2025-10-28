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
      stream = params[:stream] == 'true' || params[:stream] == true
      conversation_id = params[:conversation_id]&.strip
      
      # Handle sources array (new checkbox UI) or single source (legacy dropdown)
      sources_array = params[:sources]
      source_param = params[:source] || 'legislation'
      
      # Determine effective source from checkboxes or dropdown
      source = if sources_array.is_a?(Array) && sources_array.any?
        # Multiple sources selected - convert to symbol(s)
        valid_sources = sources_array.map(&:to_s).select { |s| %w[legislation jurisprudence parliamentary].include?(s) }
        if valid_sources.length == 1
          valid_sources.first.to_sym
        elsif valid_sources.length > 1
          :custom  # Multiple sources - we'll handle this specially
        else
          :legislation
        end
      else
        source_param.to_s.to_sym
      end
      
      @selected_sources = sources_array.is_a?(Array) ? sources_array.map(&:to_sym) : [source]

      # Validation
      if question.blank?
        return render json: { error: 'Question is required' }, status: :bad_request
      end

      unless %w[nl fr].include?(language)
        return render json: { error: 'Language must be nl or fr' }, status: :bad_request
      end

      valid_sources = %i[legislation jurisprudence parliamentary all custom]
      unless valid_sources.include?(source)
        return render json: { 
          error: 'Source must be: legislation, jurisprudence, parliamentary, or all' 
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
        model = params[:model]  # Optional model override for testing (e.g., 'gpt-4o')
        chatbot = LegalChatbotService.new(language: language, conversation: conversation, model: model)
        
        # Handle custom multi-source selection
        if source == :custom
          result = chatbot.ask_with_sources(question, sources: @selected_sources)
        else
          result = chatbot.ask(question, source: source)
        end
        
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

    # POST /api/chatbot/feedback
    # Store user feedback on chatbot answers
    def feedback
      ChatbotFeedback.ensure_table_exists

      feedback = ChatbotFeedback.new(
        question: params[:question],
        answer: params[:answer],
        feedback_type: params[:feedback_type],
        language: params[:language],
        source: params[:source],
        user: (respond_to?(:current_user, true) ? current_user : nil),
        ip_hash: Digest::SHA256.hexdigest("#{request.remote_ip}#{Rails.application.secret_key_base}")
      )

      if feedback.save
        render json: { success: true }
      else
        render json: { error: feedback.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
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
      # Legacy passphrase access (admin/testing) - check first
      passphrase = ENV['CHATBOT_PASSPHRASE']
      if passphrase.present?
        provided = params[:pass].to_s
        if ActiveSupport::SecurityUtils.secure_compare(provided, passphrase)
          return true
        end
      end
      
      # Allow authenticated users with chatbot access
      if respond_to?(:current_user, true) && current_user&.can_use_chatbot?
        return true
      end
      
      # No valid access method
      if respond_to?(:current_user, true) && current_user
        render json: { error: 'Chatbot access requires active subscription' }, status: :payment_required
      else
        render json: { error: 'Authentication required' }, status: :unauthorized
      end
      false
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

    public

    # POST /api/chatbot/save
    # Save an answer to user's profile
    def save
      unless respond_to?(:current_user, true) && current_user
        return render json: { error: 'Login required to save answers' }, status: :unauthorized
      end

      saved = current_user.saved_answers.create(
        question: params[:question],
        answer: params[:answer],
        sources: params[:sources],
        language: params[:language] || 'nl',
        title: params[:title],
        category: params[:category]
      )

      if saved.persisted?
        render json: { success: true, id: saved.id }
      else
        render json: { error: saved.errors.full_messages.join(', ') }, status: :unprocessable_entity
      end
    end

    # GET /api/chatbot/saved
    # Get user's saved answers
    def saved
      unless respond_to?(:current_user, true) && current_user
        return render json: { error: 'Login required' }, status: :unauthorized
      end

      answers = current_user.saved_answers.recent
      answers = answers.by_category(params[:category]) if params[:category].present?
      answers = answers.limit(params[:limit] || 50)

      render json: {
        answers: answers.map { |a| 
          { 
            id: a.id, 
            question: a.question, 
            answer: a.answer[0..500], 
            sources: a.sources,
            title: a.title,
            category: a.category,
            created_at: a.created_at 
          } 
        },
        categories: (current_user ? SavedAnswer.categories_for_user(current_user) : [])
      }
    end

    # DELETE /api/chatbot/saved/:id
    def destroy_saved
      unless respond_to?(:current_user, true) && current_user
        return render json: { error: 'Login required' }, status: :unauthorized
      end

      answer = current_user.saved_answers.find_by(id: params[:id])
      if answer&.destroy
        render json: { success: true }
      else
        render json: { error: 'Answer not found' }, status: :not_found
      end
    end
  end
end
