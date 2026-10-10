# frozen_string_literal: true

class ChatbotController < ApplicationController
  def index
    @language = params[:language] || I18n.locale.to_s
    @source = params[:source] || 'legislation'

    unless current_user
      # Account required for chatbot access
      # Preserve return path so user comes back to chatbot after login
      # Public source references survive sign-in, but a legacy ?q= link must
      # not embed a legal question inside an unfiltered redirect_to parameter.
      return_path = chatbot_path(draft_reference_params)
      redirect_to login_path(redirect_to: return_path), alert: t('auth.login_required')
      return
    end

    # Ask AI is an editable draft, not consent to make a billable request. Only
    # a public corpus reference crosses the login flow; resolve its title now
    # and transport the draft in a fragment, filtered from redirect logs.
    if params[:draft_source].present?
      title = draft_document_title
      return redirect_to chatbot_path unless title.present?

      prefix = case I18n.locale when :fr then 'Expliquez :' when :de then 'Erklären Sie:' when :en then 'Explain:' else 'Leg uit:' end
      return redirect_to "#{chatbot_path}#q=#{ERB::Util.url_encode("#{prefix} #{title}".truncate(2000))}&draft=1", allow_other_host: false
    end

    # Old links with a direct question still work for an authenticated reader,
    # but become drafts too. They are never copied into cookies or persistence.
    if params[:q].is_a?(String) && params[:q].strip.present?
      return redirect_to "#{chatbot_path}#q=#{ERB::Util.url_encode(params[:q].strip.truncate(2000))}&draft=1", allow_other_host: false
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
      hero_handoff_settings.each do |key, value|
        fragment += "&#{key}=#{ERB::Util.url_encode(value)}"
      end
      redirect_to "#{base}##{fragment}", allow_other_host: false
    else
      redirect_to base
    end
  end

  # POST /chatbot/ask - retired (WW-SEC-17). It checked the balance, generated
  # an answer and only then debited, ignoring a debit that failed, so two
  # requests on a last credit got two paid answers for one credit. No page
  # has called it since the chatbot moved to /api/chatbot/ask, which reserves
  # credits before any provider work. It answers 410 and reaches neither a
  # provider nor the credit ledger.
  def ask
    head :gone
  end

  private

  # Only public configuration codes cross the fragment handoff. This does not
  # grant access: the normal send-time/API entitlement checks still apply.
  def hero_handoff_settings
    intelligence = params[:intelligence]
    model = params[:model]
    levels = LegalChatbotService::INTELLIGENCE_LEVELS
    settings = {}
    if intelligence.is_a?(String) && levels.key?(intelligence)
      settings['intelligence'] = intelligence
      settings['model'] = model if model.is_a?(String) && levels[intelligence][:models].key?(model)
    end
    if params[:sources].is_a?(String) && params[:sources].bytesize <= 256
      sources = params[:sources].split(',').select { |source| ChatbotSourceCategories::ALL.include?(source) }.uniq
      settings['sources'] = sources.join(',') if sources.any?
    end
    settings
  end

  def draft_reference_params
    source = params[:draft_source]
    identifier = params[:draft_id]
    language = params[:draft_language]
    return {} unless source.is_a?(String) && identifier.is_a?(String) && language.is_a?(String)
    return {} if source.bytesize > 20 || identifier.bytesize > 32 || language.bytesize > 1

    valid = case source
            when 'legislation'
              %w[1 2 3].include?(language) && identifier.match?(/\A(?:[0-9A-Z]{10}|FISCONET_[0-9]{1,6})\z/)
            when 'jurisprudence', 'parliamentary'
              %w[1 2].include?(language) && identifier.match?(/\A[1-9][0-9]{0,17}\z/)
            end
    valid ? { draft_source: source, draft_id: identifier, draft_language: language } : {}
  end

  def draft_document_title
    reference = draft_reference_params
    return if reference.empty?

    source, identifier, language = reference.values_at(:draft_source, :draft_id, :draft_language)
    language_id = language.to_i
    case source
    when 'legislation'
      served_legislation.where(numac: identifier, language_id: language_id).pick(:title)
    when 'jurisprudence', 'parliamentary'
      path = source == 'jurisprudence' ? ENV.fetch('JURISPRUDENCE_SOURCE_DB', Rails.root.join('storage', 'jurisprudence.db').to_s) : ENV.fetch('CHAMBER_DB', Rails.root.join('storage', 'chamber.sqlite3').to_s)
      return unless File.file?(path)

      db = SQLite3::Database.new(path, readonly: true)
      db.busy_timeout = 3000
      if source == 'jurisprudence'
        row = db.get_first_row('SELECT case_number, language_id FROM cases WHERE id = ? LIMIT 1', [identifier.to_i])
        row[0] if row && row[1].to_i == language_id
      else
        row = db.get_first_row('SELECT title, language FROM documents WHERE id = ? LIMIT 1', [identifier.to_i])
        row_language = row && row[1].to_s.upcase.start_with?('F') ? 2 : 1
        row[0] if row && row_language == language_id
      end
    end
  rescue ActiveRecord::ActiveRecordError, SQLite3::Exception => e
    Rails.logger.warn("Chatbot public draft lookup unavailable: #{e.class}")
    nil
  ensure
    db&.close
  end

  def queries_remaining
    return nil unless current_user

    current_user.total_available_credits
  end
end
