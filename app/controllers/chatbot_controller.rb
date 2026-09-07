# frozen_string_literal: true

class ChatbotController < ApplicationController
  before_action :check_access, only: [:ask]
  before_action :check_usage_limit, only: [:ask]

  def index
    @language = params[:language] || I18n.locale.to_s
    @source = params[:source] || 'legislation'

    unless current_user
      # Account required for chatbot access
      # Preserve return path so user comes back to chatbot after login
      redirect_to login_path(redirect_to: request.fullpath), alert: t('auth.login_required')
      return
    end

    # Hero form handoff: the question is not persisted. After this request it is
    # passed in a URL hash fragment, which browsers do not send to the server.
    @pending_question = nil
    @queries_remaining = queries_remaining
  end

  # POST /chatbot - hero form handoff.
  # Redirects to GET /chatbot with the question in a URL hash fragment.
  # Hash fragments are not sent to the server or in referrer headers. The POST
  # is processed transiently, then the question is not stored server-side or in
  # a question-bearing cookie.
  def create
    q = params[:q].to_s.strip.truncate(2000)
    base = chatbot_path
    if q.present?
      # URI-encode the question for safe hash fragment transport
      # Also pass profile if provided (from hero sample question clicks)
      fragment = "q=#{ERB::Util.url_encode(q)}"
      profile = params[:profile].to_s.strip
      fragment += "&profile=#{ERB::Util.url_encode(profile)}" if profile.present? && LegalChatbotService.profile_exists?(profile)
      redirect_to "#{base}##{fragment}", allow_other_host: false
    else
      redirect_to base
    end
  end

  def ask
    question = params[:question]&.strip
    @language = params[:language].presence || I18n.locale.to_s
    @source = params[:source].presence || 'legislation'
    @model = params[:model].presence || 'gpt-5-mini'

    if question.blank?
      @error = @language == 'fr' ? 'La question est obligatoire' : 'Vraag is verplicht'
      render :index and return
    end

    @language = 'nl' unless %w[nl fr de en].include?(@language)

    # Validate model access for authenticated users
    if current_user && !LegalChatbotService.model_allowed?(@model, current_user.current_tier)
      @error = t('chatbot.model_not_available', model: @model)
      render :index and return
    end

    source_sym = @source.to_sym
    # Only allow known sources (chatbot is behind auth, so jurisprudence is GDPR-safe)
    source_sym = :legislation unless %i[legislation parliamentary jurisprudence].include?(source_sym)

    # Cost caps — same enforcement as the API path (this path previously
    # bypassed the per-model daily and provider estimated-spend circuit breakers)
    if LegalChatbotService.model_at_daily_cap?(@model) || LegalChatbotService.provider_at_monthly_cap?(@model)
      @error = t('chatbot.capacity_limit', default: 'Dagelijkse limiet bereikt. Probeer het later opnieuw.')
      render :index and return
    end

    # The third-party dossier lookup was removed on 2026-08-08 with the rest of that
    # integration. It was already inert: its credentials had left the server environment
    # the same day.
    case_context = nil
    service = LegalChatbotService.new(language: @language, model: @model, case_context: case_context)

    @result = service.ask(question, source: source_sym)

    # Track usage — only when an answer was produced. The service returns
    # { error: 'timeout' } instead of raising, and users were being charged
    # for an apology message.
    track_usage! unless @result[:error]

    @queries_remaining = queries_remaining
    render :index
  rescue StandardError => e
    Rails.logger.error("Chatbot error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    @error = case @language
             when 'fr' then "Une erreur s'est produite. Veuillez réessayer."
             when 'de' then 'Ein Fehler ist aufgetreten. Bitte versuchen Sie es erneut.'
             when 'en' then 'An error occurred. Please try again.'
             else 'Er is een fout opgetreden. Probeer het opnieuw.'
             end
    render :index
  end

  private

  def check_access
    # Require authentication - no anonymous access
    unless current_user
      if request.format.html?
        redirect_to login_path, alert: t('auth.login_required')
      else
        render json: { error: t('auth.login_required') }, status: :unauthorized
      end
      return
    end

    # Check if user can use chatbot (active account + within limits)
    return if current_user.can_use_chatbot?

    if request.format.html?
      redirect_to pricing_path, alert: t('chatbot.limit_exceeded')
    else
      render json: { error: t('chatbot.limit_exceeded') }, status: :payment_required
    end
  end

  def check_usage_limit
    return unless current_user

    source = (params[:source].presence || 'legislation').to_sym
    credit_cost = total_credit_cost(source)

    # Check if user can access the requested source
    unless current_user.can_access_source?(source)
      # :all and :custom are denied only for want of Pro (every multi-source
      # set contains a Pro source), so they must not claim a credit shortage.
      @error = case source
               when :parliamentary
                 t('chatbot.parliamentary_paid_only')
               when :jurisprudence, :all, :custom
                 t('chatbot.jurisprudence_paid_only')
               else
                 t('chatbot.insufficient_credits', cost: credit_cost)
               end
      @credits_remaining = current_user.total_available_credits
      @credit_cost = credit_cost
      render :index and return
    end

    # Check if user has enough credits
    return if current_user.has_credits?(credit_cost)

    @error = t('chatbot.insufficient_credits', cost: credit_cost, balance: current_user.credits)
    @credits_remaining = current_user.total_available_credits
    @credit_cost = credit_cost
    render :index and return
  end

  def track_usage!
    return unless current_user

    source = (params[:source].presence || 'legislation').to_sym
    # Charge base source cost PLUS the premium-model surcharge — this path
    # previously charged 1 credit flat even for premium models (12-13cr via
    # the API for the same query)
    current_user.deduct_credits_with_priority!(total_credit_cost(source), intelligence: 'smart')
  end

  # Source surcharge + the model's canonical absolute price (matches the API
  # path). The source cost already contains the one-credit base, so remove it
  # before adding the absolute model price.
  def total_credit_cost(source)
    model = params[:model].presence || 'gpt-5-mini'
    source_cost = current_user.credit_cost_for(source)
    model_cost = if LegalChatbotService::AVAILABLE_MODELS.key?(model)
                   LegalChatbotService.canonical_credits_for_model(model)
                 else
                   1
                 end
    source_cost + model_cost - 1
  end

  def queries_remaining
    return nil unless current_user

    current_user.total_available_credits
  end
end
