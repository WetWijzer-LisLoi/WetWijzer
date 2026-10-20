# frozen_string_literal: true

# Service class for AI-powered legal Q&A using RAG (Retrieval Augmented Generation)
# Uses explicitly configured EU-scoped routes across Azure OpenAI, Mistral,
# and AWS Bedrock; see ModelsConfig for each deployment boundary.
class LegalChatbotService
  include LegalChatbot::ModelsConfig
  include LegalChatbot::Prompts
  include LegalChatbot::Profiles
  include LegalChatbot::CoreLawMappings
  include LegalChatbot::TextProcessing
  include LegalChatbot::LanguageDetection
  include LegalChatbot::Orchestrator
  include LegalChatbot::CitationRepair
  include LegalChatbot::SearchFanOut
  include LegalChatbot::SourceFields
  include LegalChatbot::TopicCitations
  include LegalChatbot::AnswerGuards
  include LegalChatbot::AnswerLinking

  MAX_QUESTION_LENGTH = 2000
  DEEP_ANALYSIS_MAX_LENGTH = 5000
  RETRY_RESERVE_SECONDS = 60.0
  LEGAL_DISCLAIMERS = {
    'nl' => 'Dit is geen officieel juridisch advies.',
    'fr' => "Ceci n'est pas un avis juridique officiel.",
    'de' => 'Dies ist keine offizielle Rechtsberatung.',
    'en' => 'This is not official legal advice.'
  }.freeze
  OFFICIAL_SOURCE_REMINDERS = {
    'nl' => 'Controleer altijd de officiële bronnen.',
    'fr' => 'Vérifiez toujours avec les sources officielles.',
    'de' => 'Prüfen Sie immer die offiziellen Quellen.',
    'en' => 'Always verify with official sources.'
  }.freeze

  # A bare legal-form reply can safely inherit only the immediately preceding
  # generic formation-deed question. It must remain a single form token so a
  # typed multi-form comparison can never be silently rewritten.
  FORMATION_DEED_FORM_FOLLOWUP_REPLY = /\A(?:(?:de|het|la|le|the|een|un|une)\s+)?(?:bv(?:ba)?|cv(?:ba)?|nv|srl|vzw|asbl|ivzw|aisbl|stichting|fondation|(?-i:SC)|(?-i:SA))\.?\z/i

  # This legacy path is used only by the offline article backfill below. Live
  # chatbot questions use LegalChatbot::EmbeddingService, which deliberately
  # never writes question text, hashes, or vectors to a shared cache.
  ARTICLE_EMBEDDING_CACHE_TTL = 1.hour

  def initialize(language: 'nl', conversation: nil, model: nil, domain: nil, concise: false, case_context: nil, reasoning_effort: nil, research_depth: nil, profile: 'general', context_messages_override: nil, law_numac: nil, include_quality_evidence: false, mistral_api_key_env: 'MISTRAL_API_KEY', german_lane: false, request_deadline_at: nil, answer_language_override: nil, site_language_policy: true)
    @language = language
    @configured_language = language
    @answer_language_override = answer_language_override.to_s.downcase.presence
    @answer_language_override = nil unless LEGAL_DISCLAIMERS.key?(@answer_language_override)
    @site_language_policy = site_language_policy != false
    # The German pointer lane (D6 of docs/ops/german-corpus-plan-2026-09-27.md).
    # Only Api::ChatbotController sets it, from request.host through SiteBrand
    # and never for signed service traffic; every other constructor keeps the
    # default. It is still inert unless GERMAN_LANE_MODE is set (german_lane?).
    @german_lane = german_lane == true
    @domain = domain # Exact configured product host, never a browser locale.
    @language_id = %w[fr de].include?(language) ? 2 : 1 # Search is bilingual; this only affects context enrichment
    @conversation = conversation
    @context_numacs = conversation&.context_numacs_array || []
    # Merge in the law NUMAC from the page the user is viewing (chatbot widget on law pages)
    @context_numacs = (@context_numacs + [law_numac]).compact.uniq if law_numac.present?
    @model_override = model # Allow testing different models
    @concise = concise # WhatsApp/API: brief strict answers, no hedging
    @case_context = case_context # firm-specific case context injection (no live producer)
    @research_depth = self.class.normalize_research_depth(research_depth)
    # Admission resolves access/billing first. An explicit effective effort
    # must not be upgraded here (notably free users and Mistral follow-ups).
    @reasoning_effort = reasoning_effort ||
                        self.class.reasoning_effort_for_research_depth(@research_depth, model: model || self.class::CHAT_MODEL) || 'low'
    @profile = profile # Category profile for domain-specific law boosting
    @context_messages_override = context_messages_override # ZK mode: client provides context
    @include_quality_evidence = include_quality_evidence == true
    @mistral_api_key_env = mistral_api_key_env
    # Monotonic request deadline supplied by the streaming controller. It is
    # deliberately optional for service callers and never persisted or sent
    # to a provider.
    @request_deadline_at = request_deadline_at&.to_f
  end

  private

  # One language decision for the complete answer pipeline, made from the
  # original typed question before retrieval adds context or legal-form names.
  # Generation, repair, notices, guarded fallbacks and suggestions must not
  # each make a different decision. NL/FR/DE sites keep their configured
  # default; EN/INT follows input. An explicit supported language request wins.
  # GesetzGuide's default/explicit DE still reasons in FR before translation.
  def resolve_answer_language!(question)
    requested = @answer_language_override || LegalChatbot::LanguageDetection.requested_answer_language(question)
    @resolved_language_override = requested
    german_pipeline = @german_lane || (@site_language_policy && SiteBrand.resolve_host(@domain) == 'gesetzguide')
    resolved = if german_pipeline && (requested.nil? || requested == 'de')
                 'fr'
               elsif requested
                 requested
               elsif configured_answer_language == 'en'
                 previous = begin
                   conversation_messages.rfind { |message| message[:role].to_s == 'user' }&.fetch(:content, nil)
                 rescue StandardError
                   nil
                 end
                 detect_question_language(question, fallback: 'en', previous_question: previous).to_s
               else
                 configured_answer_language
               end
    international = configured_answer_language == 'en' && requested.nil?
    if resolved != @language.to_s || @international_input_language != international
      # Instances are normally per request, but supported reuse must not keep
      # a previous language in a memoized prompt/search/source collaborator.
      %i[embedding_svc llm_svc context_builder_svc source_formatter_svc
         reference_sheets_svc legislation_search_svc jurisprudence_search_svc
         parliamentary_search_svc fisconet_search_svc regional_search_svc eu_search_svc].each do |name|
        remove_instance_variable(:"@#{name}") if instance_variable_defined?(:"@#{name}")
      end
    end
    @resolved_answer_language = @language = resolved
    @international_input_language = international
    @language_id = %w[fr de].include?(resolved) ? 2 : 1
    resolved
  end

  def configured_answer_language
    brand = SiteBrand.resolve_host(@domain) if @site_language_policy
    configured = SiteBrand.locale_for(brand) || @configured_language.to_s.downcase
    LEGAL_DISCLAIMERS.key?(configured) ? configured : 'nl'
  end

  # Build conversation history messages for LLM context (follow-up questions)
  # Returns array of {role:, content:} hashes from previous exchanges
  #
  # Two modes:
  # 1. Legacy: reads from @conversation.messages_array (server-side storage)
  # 2. Zero-knowledge: uses @context_messages_override (client provides context)
  def conversation_messages
    # ZK mode: client provided the context directly
    if @context_messages_override.present?
      return strip_retrieval_notice_from_history(
        @context_messages_override.last(6).map { |m| history_message(m) }
      )
    end

    return [] unless @conversation

    msgs = @conversation.messages_array
    return [] if msgs.empty?

    # Take last 6 messages (3 exchanges) for context
    strip_retrieval_notice_from_history(
      msgs.last(6).map { |m| history_message(m) }
    )
  end

  def expand_formation_deed_followup(question)
    original = question.to_s
    reply = original.strip
    return question unless reply.match?(FORMATION_DEED_FORM_FOLLOWUP_REPLY)

    history = begin
      conversation_messages
    rescue StandardError
      []
    end
    previous = Array(history).rfind do |message|
      message.is_a?(Hash) && message[:role].to_s == 'user'
    end
    return question unless previous && previous[:content].is_a?(String)

    previous_question = previous && previous[:content].strip
    return question if previous_question.blank? || previous_question.length > MAX_QUESTION_LENGTH

    intent = previous_question.gsub(/[[:space:]]+/, ' ')
    return question unless intent.match?(LegalChatbot::LegislationSearch::FORMATION_DEED_PATTERN)
    return question unless intent.match?(LegalChatbot::LegislationSearch::FORMATION_DEED_GENERIC_PATTERN)
    return question unless LegalChatbot::LegislationSearch.formation_deed_entity_context?(intent)

    "#{previous_question}\n#{reply}"
  end

  # One history entry as the model is shown it. An assistant turn that
  # carries context_content (GermanAnswerTranslation::CONTEXT_KEY: the French
  # answer a German answer on gesetzguide was made from) is replayed as that
  # French text, so a follow-up reasons on the same assistant turns as on
  # lisloi and never on a translation. A user turn that carries it (the
  # French question a German question was translated into, German answers
  # v3) is replayed as that French question, so the whole history is the one
  # lisloi would have. Both routes carry it: the browser sends it back in
  # context_messages (the controller keeps it on a user turn only while the
  # question translation applies), a stored conversation keeps it in the
  # message. Any other turn is replayed as typed.
  def history_message(message)
    role = message['role'] || message[:role]
    content = message['content'] || message[:content]
    key = LegalChatbot::GermanAnswerTranslation::CONTEXT_KEY
    replayed = message[key.to_s] || message[key]
    content = replayed if replayed.is_a?(String) && replayed.strip != ''
    { role: role, content: content }
  end

  # The retrieval notice never goes back to the model. It is stored verbatim
  # with the answer (api/conversation_persistence.rb:121 writes result[:answer])
  # and both history routes replay that text: stored messages above, and
  # params[:context_messages] for ZK and non-consented sessions. Replaying it
  # teaches the model to open the NEXT answer with "de zoekopdracht was
  # onvolledig" on a pass where nothing was degraded - a warning that fires on
  # healthy behaviour, invisible to the only measurement channel there is,
  # since [RetrievalDegraded] is logged from the fan-out and the echoed copy
  # sets no :retrieval_degraded key. Orchestrator#apply_retrieval_notice! also
  # strips an echo out of the outgoing answer; this stops it one step earlier.
  # Assistant turns only: a user who types the sentence keeps it.
  #
  # The German site's "shown in French" note (GermanAnswerTranslation) is
  # stripped for the same reason: echoed into the next French answer, it
  # would be translated and served as if it described that answer. No other
  # site's answers ever carry it, so for them this is a no-op. The same holds
  # for the figure note of German answers v4 (GermanFigureCheck), which the
  # answer turn replays without in any case (its context_content).
  def strip_retrieval_notice_from_history(messages)
    messages.map do |message|
      next message unless message[:role].to_s == 'assistant'

      content = without_retrieval_notice(message[:content])
      content = LegalChatbot::GermanAnswerTranslation.without_french_note(content)
      message.merge(content: LegalChatbot::GermanFigureCheck.without_note(content))
    end
  end

  public

  # Main method to answer a question
  def ask(question, source: :all, max_length: MAX_QUESTION_LENGTH)
    start_time = Time.current
    resolve_answer_language!(question)

    # Timeout wrapper to prevent hanging requests
    # Reasoning models need more time for chain-of-thought, and some
    # non-reasoning models (mistral-large-4) are simply slow completers:
    # both classes get the long budget. Reasoning-capability alone handed
    # the slowest model the shortest timeout (17/40 deterministic timeouts
    # on the 2026-08-13 capture).
    reasoning_model = REASONING_CAPABLE_MODELS.include?(@model_override) ||
                      LegalChatbot::ModelsConfig::SLOW_COMPLETION_MODELS.include?(@model_override)
    timeout = if max_length > MAX_QUESTION_LENGTH
                # deep_analysis (buffered, no SSE heartbeats). MUST stay under the
                # nginx proxy_read_timeout (150s) so nginx never 504s a request
                # the server would still answer; otherwise the client sees an
                # error while the server completes and charges for a lost answer.
                140
              elsif reasoning_model
                # Must exceed the LLM client's 165s high-effort read_timeout, or a
                # still-generating reasoning answer is killed and the user charged
                # for nothing. Matches ask_with_sources.
                180
              else
                90 # Bilingual translations + FAISS + LLM can take 60-80s
              end
    return timeout_result(start_time) if request_deadline_expired?

    with_request_deadline(timeout) do
      ask_internal(question, source: source, max_length: max_length)
    end
  rescue Timeout::Error
    Rails.logger.warn("[ChatbotTimeout] kind=service model=#{@model_override || 'default'} duration_ms=#{((Time.current - start_time) * 1000).round}")
    {
      answer: timeout_answer,
      sources: [],
      language: @language,
      response_time: (Time.current - start_time).round(2),
      error: 'timeout'
    }
  end

  # Ask with multiple sources (checkbox UI)
  # sources: array of symbols like [:legislation, :jurisprudence, :parliamentary]
  def ask_with_sources(question, sources: [:legislation])
    start_time = Time.current
    resolve_answer_language!(question)
    # Reasoning-aware timeout (matches ask() method logic, incl. the
    # slow-completion class - see SLOW_COMPLETION_MODELS).
    reasoning_model = REASONING_CAPABLE_MODELS.include?(@model_override) ||
                      LegalChatbot::ModelsConfig::SLOW_COMPLETION_MODELS.include?(@model_override)
    timeout = reasoning_model ? 180 : 120
    return timeout_result(start_time) if request_deadline_expired?

    with_request_deadline(timeout) do
      ask_internal_multi(question, sources: sources)
    end
  rescue Timeout::Error
    Rails.logger.warn("[ChatbotTimeout] kind=service model=#{@model_override || 'default'} duration_ms=#{((Time.current - start_time) * 1000).round}")
    {
      answer: timeout_answer,
      sources: [],
      language: @language,
      response_time: (Time.current - start_time).round(2),
      error: 'timeout'
    }
  end

  # Localized timeout message (previously NL/FR only - DE/EN users got Dutch)
  def timeout_answer
    case @language
    when 'fr' then "Le traitement a pris trop de temps. Veuillez réessayer."
    when 'de' then 'Die Verarbeitung hat zu lange gedauert. Bitte versuchen Sie es erneut.'
    when 'en' then 'The processing took too long. Please try again.'
    else 'De verwerking duurde te lang. Probeer opnieuw.'
    end
  end

  def remaining_request_seconds(fallback)
    return fallback unless @request_deadline_at

    remaining = @request_deadline_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    remaining.positive? ? remaining : 0.001
  end

  def request_deadline_expired?
    @request_deadline_at && @request_deadline_at <= Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def with_request_deadline(timeout, &)
    previous = @request_deadline_at
    own_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    @request_deadline_at = previous ? [previous, own_deadline].min : own_deadline
    Timeout.timeout([timeout, remaining_request_seconds(timeout)].min, &)
  ensure
    @request_deadline_at = previous
  end

  def timeout_result(start_time)
    Rails.logger.warn("[ChatbotTimeout] kind=deadline model=#{@model_override || 'default'} duration_ms=#{((Time.current - start_time) * 1000).round}")
    {
      answer: timeout_answer,
      sources: [],
      language: @language,
      response_time: (Time.current - start_time).round(2),
      error: 'timeout'
    }
  end

  def enough_request_time?(minimum_seconds = nil)
    return true unless @request_deadline_at

    minimum = minimum_seconds || minimum_retry_seconds
    (@request_deadline_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)) >= minimum
  end

  def minimum_retry_seconds
    observed = @llm_svc&.last_provider_duration_seconds.to_f
    # A retry must have room for a call comparable to the previous one, plus
    # verification and delivery. With no observation, use a conservative
    # code-owned reserve; never enlarge the hard request deadline.
    return RETRY_RESERVE_SECONDS unless observed.positive?

    [20.0, observed + 15.0].max
  end

  # Internal method for multi-source search
  # Delegates to the Orchestrator concern for clean service object wiring.
  # See app/services/legal_chatbot/orchestrator.rb for the implementation.
  def ask_internal_multi(question, sources: [:legislation], max_length: MAX_QUESTION_LENGTH)
    return { answer: 'Stel een vraag.', sources: [] } if question.blank?
    raise ArgumentError, 'Question too long' if question.length > max_length

    orchestrated_multi_search(question, sources: sources)
  end

  def ask_internal(question, source: :legislation, max_length: MAX_QUESTION_LENGTH)
    return { answer: 'Stel een vraag.', sources: [] } if question.blank?
    raise ArgumentError, 'Question too long' if question.length > max_length

    # Route all single-source requests through the orchestrator.
    # Maps legacy :all → multi-source, single source → single-element array.
    sources = case source
              when :all
                %i[legislation jurisprudence parliamentary]
              else
                [source]
              end

    orchestrated_multi_search(question, sources: sources)
  end

  # ─── SEARCH METHODS (EXTRACTED) ───────────────────────────────────────
  # All search logic has been extracted to service objects:
  #   LegalChatbot::LegislationSearch   (FAISS 8767, FTS5, boosting)
  #   LegalChatbot::JurisprudenceSearch (FAISS 8765, SQLite)
  #   LegalChatbot::ParliamentarySearch (FAISS 8769, SQLite)
  #   LegalChatbot::FisconetSearch      (FAISS 8768, SQLite)
  #   LegalChatbot::RegionalSearch      (FAISS 8770)
  #
  # Both ask() and ask_with_sources() route through the Orchestrator concern
  # which coordinates these services. See orchestrator.rb.
  # ────────────────────────────────────────────────────────────────────────

  # Simple tax-topic detection used by orchestrator to decide whether
  # to spawn the Fisconet search thread.
  def is_tax_question?(question_lower)
    LegalChatbot::FisconetSearch.tax_question?(question_lower)
  end

  # A source flagged by retrieval as carrying a not-yet-in-force amendment. The text in the
  # block is the in-force half; this says a change exists and, for about a third of them,
  # when it starts. It goes on the HEADER line because every text slice is a silent prefix
  # cut with no ellipsis, so anything appended to the body can simply vanish.
  def future_amendment_note(source)
    return '' unless source[:future_amendment]

    date = source[:future_effective_date]
    if @language == 'fr'
      " [modification pas encore en vigueur#{date ? " (#{date})" : ''}]"
    else
      " [wijziging nog niet in werking#{date ? " (vanaf #{date})" : ''}]"
    end
  end

  # Build combined context from legislation, jurisprudence, parliamentary
  # works, tax legislation, regional legislation, and sealed official EU
  # sources admitted by LegalFactProvider.
  def build_combined_context_from_db(
    articles,
    cases,
    parl_docs = [],
    tax_articles = [],
    regional_docs = [],
    max_article_chars: 4000,
    authoritative_docs: [],
    question: nil
  )
    parts = []
    juris_label = @language == 'fr' ? 'JURISPRUDENCE' : 'RECHTSPRAAK'
    parl_label = @language == 'fr' ? 'TRAVAUX PRÉPARATOIRES' : 'PARLEMENTAIRE VOORBEREIDING'

    # A German row reaches the model only as a binding German original
    # (german_original_source?). Any other language 3 row, whatever path
    # brought it, is dropped here, so it can never be read as evidence, nor
    # labelled 'FR' by the binary label below.
    articles = Array(articles).reject { |article| german_row_source?(article) && !german_original_source?(article) }

    # Complete blocks only (r47): the caller passes the sources
    # admit_statutory_sources admitted; nothing here excerpts or cuts.
    articles.each_with_index do |article, index|
      parts << legislation_context_block(article, index + 1)
    end

    cases.each_with_index do |c, index|
      lang_label = source_context_language(c)
      text = LegalChatbot::SourcePassageExcerpt.excerpt(
        ensure_utf8(c[:full_text]), question, max_chars: max_article_chars, summary: ensure_utf8(c[:summary])
      )
      judicial_kind = if LegalChatbot::AdvisoryOpinions.advisory?(c[:case_number])
                        'legislative_opinion'
                      else
                        c[:judicial_kind].presence ||
                          LegalChatbot::JurisprudenceSearch.source_metadata(case_number: c[:case_number])[:judicial_kind].presence ||
                          'case_law_collection'
                      end
      metadata = source_context_metadata(c, kind: judicial_kind)
      ecli = c[:case_number]
      link = ecli ? "/jurisprudence/#{ecli}" : nil
      if LegalChatbot::AdvisoryOpinions.advisory?(ecli)
        advisory_label = { 'en' => 'COUNCIL OF STATE LEGISLATIVE OPINION',
                           'de' => 'GUTACHTEN DES STAATSRATS (GESETZGEBUNG)' }[@language] ||
                         LegalChatbot::AdvisoryOpinions.source_label(@language)
        identity = if %w[en de].include?(@language)
                     ["Opinion: #{LegalChatbot::AdvisoryOpinions.number(ecli)}", "Authority: #{c[:court]}",
                      'SOURCE KIND: legislative advice on draft rules, not a court judgment or binding legislation.']
                   else
                     LegalChatbot::AdvisoryOpinions.context_header(ecli, c[:court], @language)
                   end
        parts << "[Bron #{articles.size + index + 1} - #{advisory_label} (#{lang_label})]\n#{identity.join("\n")}\nDatum: #{c[:decision_date]}\n#{metadata}#{"\nLINK: #{link}" if link}\n#{text}"
      else
        label = if judicial_kind.to_s.include?('opinion')
                  { 'fr' => 'AVIS CONSULTATIF', 'de' => 'GUTACHTEN', 'en' => 'ADVISORY OPINION' }.fetch(@language, 'ADVIES')
                else
                  juris_label
                end
        parts << "[Bron #{articles.size + index + 1} - #{label} (#{lang_label})]\nECLI: #{ecli}\nHof: #{c[:court]}\nDatum: #{c[:decision_date]}\n#{metadata}#{"\nLINK: #{link}" if link}\n#{text}"
      end
    end

    parl_docs.each_with_index do |doc, index|
      parliament_name = case doc[:parliament]
                        when 'chamber' then 'Kamer'
                        when 'senate' then 'Senaat'
                        else doc[:parliament]&.capitalize
                        end
      text = LegalChatbot::SourcePassageExcerpt.excerpt(
        ensure_utf8(doc[:content]), question, max_chars: max_article_chars, summary: ensure_utf8(doc[:summary])
      )
      metadata = source_context_metadata(doc, kind: 'parliamentary_preparation')
      link = parliamentary_search_svc.source_url(doc)
      resolution_note = parliamentary_search_svc.resolution_context_note(doc)
      parts << "[Bron #{articles.size + cases.size + index + 1} - #{parl_label}]\nParlement: #{parliament_name}\nDossier: #{doc[:dossier]}/#{doc[:document_number]}\n#{metadata}#{"\n#{resolution_note}" if resolution_note}#{"\nLINK: #{link}" if link}\n#{text}"
    end

    tax_articles.each_with_index do |art, index|
      parts << tax_context_block(art, articles.size + cases.size + parl_docs.size + index + 1)
    end

    # Regional legislation (Vlaamse Codex, Wallex, Brussels)
    regional_docs.each_with_index do |doc, index|
      parts << regional_context_block(doc, articles.size + cases.size + parl_docs.size + tax_articles.size + index + 1)
    end

    # These are tiny, code-sealed excerpts from an official source, not
    # arbitrary external documents. Preserve enough text for all Art. 28(3)
    # duties even on the low-cost tier; the provider rejects malformed URLs or
    # incomplete source sets before records reach this method.
    authoritative_docs.each_with_index do |doc, index|
      offset = articles.size + cases.size + parl_docs.size + tax_articles.size + regional_docs.size
      block = authoritative_context_block(doc, offset + index + 1, question: question, max_article_chars: max_article_chars)
      parts << block if block
    end

    # Last, so it sits closest to where generation begins. Measured on production
    # 2026-08-07: with the rule ONLY in the system prompt, an erfbelasting question
    # retrieved art. 3 and art. 4 as its top two sources and the answer cited neither and
    # never said the tax was regional. The default model is small and the system prompt is
    # long; a rule buried in it loses to one standing next to the evidence.
    competence = regional_tax_competence_notice(articles)
    parts << competence if competence

    formation_notice = formation_deed_context_notice(articles, question)
    parts << formation_notice if formation_notice

    parts.join("\n\n---\n\n")
  end

  # One authoritative record as its context block, or nil for an EU record
  # that does not verify (it is never shown). r47 (root 2026-10-19
  # 18:59:40): an EU statutory unit (an article, recital or final provision
  # of legislation) and a sealed official statutory record are shown
  # complete and are measured as required admission units
  # (statutory_extra_units); an EU judgment, holding or Advocate-General
  # unit and official guidance keep their bounded excerpt and their labels.
  def authoritative_context_block(doc, number, question: nil, max_article_chars: nil)
    if doc[:source] == LegalChatbot::EuCorpus::SOURCE
      return nil unless LegalChatbot::EuCorpus.verified_record?(doc)

      source_text = ensure_utf8(doc[:article_text])
      complete = eu_statutory_unit?(doc) ||
                 complete_erasure_context_article?(doc, question, source_text) ||
                 complete_platform_redress_context_article?(doc, question, source_text) ||
                 complete_flight_disruption_context_article?(doc, question, source_text)
      text = if complete
               source_text
             else
               LegalChatbot::EuArticleDependencies.excerpt(doc, source_text, question, max_chars: max_article_chars) ||
                 LegalChatbot::ArticleExcerpt.excerpt(source_text, question, max_chars: max_article_chars)
             end
      kind_notice = case doc[:kind]
                    when 'recital' then 'INTERPRETATIVE RECITAL: explain its literal content and recorded edition status only; it does not create independent obligations or override operative provisions. Do not introduce numbered operative provisions absent from supplied evidence.'
                    when 'paragraph'
                      doc[:judicial_kind] == 'advocate_general_opinion' ? 'ADVOCATE GENERAL OPINION: not a court judgment.' : 'EU CASE-LAW PARAGRAPH: identify court, procedure and edition from metadata; report what this paragraph establishes, not an invented holding. Statutory references inside it are reported court reasoning, not separately retrieved statutory provisions.'
                    when 'final'
                      if doc[:source_kind] == 'jurisprudence'
                        label = doc[:judicial_kind] == 'advocate_general_opinion' ? 'ADVOCATE GENERAL OPINION CONCLUSIONS: not a court judgment.' : 'EU COURT OPERATIVE HOLDING.'
                        "#{label} UNNUMBERED CASE-LAW UNIT: copy the exact LINK; do not invent paragraph numbers or paragraph anchors. Statutory references inside this unit are reported source text, not separately retrieved statutory provisions."
                      else
                        'OPERATIVE EU LEGAL TEXT: assess scope, legal status and application dates; this edition is not automatically the latest applicable text.'
                      end
                    else 'OPERATIVE EU LEGAL TEXT: assess scope, legal status and application dates; this edition is not automatically the latest applicable text.'
                    end
      if doc[:historical]
        coverage = doc[:correction_status].to_s.match?(/unresolved/i) ? 'correction overlays are unresolved' : 'correction coverage has not been verified'
        kind_notice += " HISTORICAL ORIGINAL EDITION: #{coverage}; do not present this wording as current or corrected EU law."
      end
      if doc[:document_type].to_s.match?(/directive|richtlijn|directiva/i) || doc[:celex].to_s.match?(/\A[03]\d{4}L/)
        kind_notice += ' DIRECTIVE: assess national transposition and applicability; do not treat every provision as directly enforceable Belgian legislation.'
      end
      text_label = complete ? 'LITERAL SOURCE TEXT (complete unit):' : 'LITERAL SOURCE TEXT (excerpt):'
      return "[Bron #{number} - EUR-LEX (#{doc[:language].upcase})]\n" \
             "CELEX: #{doc[:celex]}#{"\nECLI: #{doc[:ecli]}" if doc[:ecli].present?}\n" \
             "Title: #{doc[:law_title]}\n#{doc[:article_title]}\nSOURCE KIND: #{doc[:document_type]} / #{doc[:kind]}\n" \
             "#{kind_notice}\nDocument date: #{doc[:document_date]}\nEdition date: #{doc[:edition_date]}\n" \
             "Authentic language metadata: #{doc[:authentic_language].present? ? doc[:authentic_language].to_json : 'unknown'}; literal source language: #{doc[:language]}\n" \
             "Legal status: #{doc[:legal_status]}\nCorrection coverage: #{doc[:correction_status]}\n" \
             "Correction evidence observed at: #{doc[:correction_observed_at].presence || 'not recorded'}\n" \
             "Correction verification: #{doc[:correction_verification].presence || 'not certified'}. A verified unchanged original recital is not a certificate of current legal force.\n" \
             "CITATION RULE: copy this exact LINK for the article/recital/paragraph. Use a Markdown link, name the correct source kind and unit; never relabel a recital as an article or an opinion as a judgment.\n" \
             "OFFICIAL METADATA (identity, not a substitute for literal source text): #{eu_context_metadata(doc[:metadata])}\n" \
             "LINK: #{doc[:url]}\n#{text_label}\n#{text}"
    end

    if doc[:source] == 'official_guidance'
      # A reviewed lender/supervisor FAQ is not an EU or Belgian statute.
      # Only article_text is literal quote evidence; the separate summary
      # is editorial source-use context and may not be quoted as native text.
      text = ensure_utf8(doc[:article_text].to_s)[0..6000]
      return "[Bron #{number} - OFFICIAL GUIDANCE (#{doc[:language]})]\n" \
             "Authority: #{doc[:authority]}\nTitle: #{doc[:title]}\nVerified: #{doc[:verified_on]}\n" \
             "LINK: #{doc[:url]}\nLITERAL SOURCE EXCERPT:\n#{text}\n" \
             "REVIEWED SUMMARY (not a literal quotation or statute):\n#{doc[:reviewed_summary]}"
    end

    # A sealed official statutory record, complete: the cut at 6,001
    # characters is gone (r47).
    text = ensure_utf8(doc[:article_text].to_s)
    "[Bron #{number} - #{official_eu_label} (#{doc[:language]})]\n" \
      "Bron: #{doc[:authority]}\nWet: #{doc[:law_title]}\n#{doc[:article_title]}\n" \
      "LINK: #{doc[:url]}\n#{text}"
  end

  def official_eu_label
    case @language
    when 'fr' then 'LÉGISLATION OFFICIELLE DE L’UNION EUROPÉENNE'
    when 'de' then 'OFFIZIELLES EU-RECHT'
    when 'en' then 'OFFICIAL EU LEGISLATION'
    else 'OFFICIËLE EU-WETGEVING'
    end
  end

  # An EU unit of legislation (an article, recital or final provision), not
  # a judgment, holding or Advocate-General paragraph or conclusion.
  def eu_statutory_unit?(doc)
    doc[:source_kind].to_s != 'jurisprudence' && doc[:kind].to_s != 'paragraph'
  end

  # A record the allowance must hold complete: a verified EU statutory unit,
  # or a sealed official record that is not guidance.
  def statutory_authoritative?(doc)
    if doc[:source] == LegalChatbot::EuCorpus::SOURCE
      eu_statutory_unit?(doc) && LegalChatbot::EuCorpus.verified_record?(doc)
    else
      doc[:source] != 'official_guidance'
    end
  end

  # The EU and sealed official statutory records and the verified-data block
  # as admission units (r47; root 2026-10-19 18:59:40, coordination
  # 21:24:13), each measured at the length of what reaches the model
  # complete. Every unit is required except an EU website-overview unit
  # (EuSearch marks it eu_website_overview): that is breadth beside the
  # governing Belgian pins and sealed GDPR texts, so it is optional and is
  # left out whole when the required units fill the allowance (root
  # 2026-10-19 21:51:37 and 22:11:41). A member names its place in the caller's
  # lists: [:authoritative, index] in authoritative_docs, [:facts, 0] for the
  # block the model client prepends (facts_chars, its exact length, from
  # LlmClient#reference_facts_block). A record that is not statutory keeps
  # its own bounded excerpt and is no unit; an EU record that does not
  # verify is never rendered and is no unit either.
  def statutory_extra_units(authoritative_docs:, facts_chars:)
    units = []
    if facts_chars.to_i.positive?
      units << { kind: :fact_pack, members: [[:facts, 0]], required: true,
                 required_identities: [%w[verified_legal_data fact_block]], length: facts_chars.to_i }
    end
    Array(authoritative_docs).each_with_index do |doc, index|
      next unless statutory_authoritative?(doc)

      units << { kind: doc[:source] == LegalChatbot::EuCorpus::SOURCE ? :eu_statutory : :official_statutory,
                 members: [[:authoritative, index]], required: doc[:eu_website_overview] != true,
                 required_identities: [[doc[:celex] || doc[:url], doc[:article_title]]],
                 length: authoritative_context_block(doc, STATUTORY_MEASURE_NUMBER).to_s.length }
    end
    units
  end

  # The instruction over the German wording. French, because gesetzguide's
  # answers are French (effective_request_language) and the model obeys the
  # prompt language; it says the wording is for terminology only and that
  # only the French text above is binding and quotable.
  GERMAN_WORDING_INSTRUCTION = 'TRADUCTION ALLEMANDE DE CET ARTICLE (non contraignante; uniquement pour la ' \
                               'terminologie allemande; ne pas la citer en bloc; seul le texte français ' \
                               'ci-dessus fait foi et est cité)'

  # The German lane's sub-block for one French source: the instruction, the
  # German site's own provenance label (de.yml german_text.labels, verbatim,
  # with the Staatsblatt date) and at most WORDING_MAX_CHARS of the wording.
  # Empty unless this service runs the lane in wording mode AND the search
  # attached a verified wording (currency 'current', live French hash equal
  # to the build-time hash). The wording is never under article_text, so
  # QuoteGuard cannot certify a German blockquote against it.
  def german_wording_block(article)
    return '' unless @german_lane && LegalChatbot::GermanArticleSearch.wording?

    evidence = article[:german_evidence]
    return '' unless evidence.is_a?(Hash)

    wording = ensure_utf8(evidence[:wording].to_s).strip
    return '' if wording.empty?

    label = german_wording_label(evidence)
    excerpt = wording[0, LegalChatbot::GermanArticleSearch::WORDING_MAX_CHARS]
    ["\n\n#{GERMAN_WORDING_INSTRUCTION}", label, excerpt].compact.join("\n")
  end

  # "Offizielle deutsche Übersetzung, veröffentlicht im Belgischen Staatsblatt
  # vom 27. April 2012. ..." from the sidecar's source_method and
  # publication_date, exactly as the German law page labels the same text
  # (GermanTextHelper#german_text_notice). nil for an unknown source_method.
  def german_wording_label(evidence)
    key = GermanTextProvenance.label_key(evidence[:source_method])
    return nil unless key

    date = begin
      Date.iso8601(evidence[:publication_date].to_s)
    rescue ArgumentError, TypeError
      nil
    end
    published = date ? " vom #{I18n.l(date, format: GermanTextHelper::GERMAN_DATE_FORMAT, locale: :de)}" : ''
    I18n.t("german_text.labels.#{key}", locale: :de, published: published, state: '')
  end

  # A binding German original (owner decision 2026-09-28): the German text
  # is the law, so its block is German whatever the answer language. It
  # keeps "Bron" and "LINK:", which every other block uses for the source
  # numbering and the HYPERLINK RULE, and adds the STAND line: the German
  # site's own provenance label with the Staatsblatt date, the version (as
  # published) and the later amending acts the build found. The STAND line
  # is never part of article_text, so QuoteGuard cannot certify it.
  GERMAN_ORIGINAL_HEADERS = { 'dekret' => 'DEKRET', 'erlass' => 'ERLASS' }.freeze
  GERMAN_ORIGINAL_INSTRUCTION = 'VERBINDLICHER DEUTSCHER ORIGINALTEXT: wörtlich auf Deutsch zitierbar; nennen Sie ' \
                                'die Fassung (STAND) und jede dort genannte spätere Änderung.'
  GERMAN_ORIGINAL_VERSION = 'Fassung: wie ursprünglich veröffentlicht; spätere Änderungen sind in diesem Text ' \
                            'nicht eingearbeitet.'
  GERMAN_ORIGINAL_NOT_AMENDED = 'Spätere Änderungen sind in den konsultierten Quellen nicht verzeichnet, aber nicht ' \
                                'ausgeschlossen.'
  GERMAN_AMENDER_KINDS = { 'dekret' => 'Dekret', 'erlass' => 'Erlass der Regierung' }.freeze

  # Source language describes the actual retrieved text, never the answer
  # language or an inferred translation. Unknown metadata stays unknown.
  def source_context_language(source)
    explicit = source[:source_language].to_s.downcase
    return explicit.upcase if %w[nl fr de en].include?(explicit)

    { 1 => 'NL', 2 => 'FR', 3 => 'DE' }[source[:language_id].to_i] || 'unknown'
  end

  # Preserve retrieval provenance at the last evidence boundary. In
  # particular, an edition/version date is NOT an effective date, and a
  # parliamentary report/advice is NOT enacted legislation. These fields
  # describe identity/status only; they are not literal quotation evidence.
  def source_context_metadata(source, kind:)
    rows = ["SOURCE KIND: #{source[:source_kind].presence || kind}", "Literal source language: #{source_context_language(source)}"]
    fields = {
      judicial_kind: 'Judicial kind', authority_kind: 'Authority kind',
      article_type: 'Article subtype', source_type: 'Source subtype',
      source_language: 'Recorded source language',
      document_type: 'Document type', status: 'Recorded document status',
      document_status: 'Recorded document status', document_date: 'Document date',
      publication_date: 'Publication date', version_date: 'Version date (not an effective date)',
      end_date: 'Recorded end date', edition_role: 'Edition role', edition_year: 'Edition year',
      jurisdiction: 'Territorial jurisdiction', region: 'Territorial region'
    }
    fields.each do |key, label|
      value = source[key]
      rows << "#{label}: #{value}" if value.present?
    end
    rows << "Recorded repealed flag: #{source[:is_abolished]}" if source.key?(:is_abolished)
    if kind == 'judgment'
      rows << 'STATUS RULE: a judgment is not legislation; applicability and precedential weight depend on its court, issue and procedural context.'
    end
    rows << 'STATUS RULE: an advisory opinion is advice, not a judgment or enacted legislation.' if kind.to_s.include?('opinion')
    if kind == 'parliamentary_preparation'
      rows << 'STATUS RULE: parliamentary preparation is interpretative/history material, not proof that a proposal was enacted or is currently applicable.'
    end
    rows.join("\n")
  end

  # A statute's text within the context budget. With the question known, the
  # cut keeps the provisions the question is about (LegalChatbot::ArticleExcerpt);
  # without it, the head of the article, as before. Judgments and reports use
  # SourcePassageExcerpt instead: their decisive reasoning may be far beyond
  # the introduction and a catalogue summary is not literal source text.
  def article_context_text(text, question, max_article_chars, article: nil)
    text = text_from_context_anchor(text, article)
    if article && (commercial_excerpt = LegalChatbot::CommercialWebsiteContext.excerpt(article, text: text, question: question))
      return commercial_excerpt
    end
    if article && (procedural_excerpt = LegalChatbot::MunicipalSanctionsContext.excerpt(article, text: text, question: question, max_chars: max_article_chars))
      return procedural_excerpt
    end

    return text[0..max_article_chars] if question.blank?

    LegalChatbot::ArticleExcerpt.excerpt(text, question, max_chars: max_article_chars + 1)
  end

  # LegislationSearch#pinned_articles marks a pin whose governing provision
  # sits deep in a long article (road code Art. 8.3., OCMW Act Art. 57 § 2.)
  # with :context_excerpt_anchor; the model's text starts there, while the
  # source card and the stored text stay whole. Until 2026-10-14 only
  # LegislationSearch#build_context read the mark, and the answer path does
  # not call it: the excerpt kept "§ 1." and "1° het verlenen van dringende
  # medische hulp" but dropped the "(§ 2. (In afwijking" line between them,
  # and the model cited the clause as "§ 1, 1°".
  def text_from_context_anchor(text, article)
    anchor = article.is_a?(Hash) ? article[:context_excerpt_anchor].to_s : ''
    return text if anchor.empty?

    offset = text.index(/(?<![\d.])#{Regexp.escape(anchor)}(?!\d)/)
    offset ? text[offset..] : text
  end

  # The verified Article17 unit contains both erasure grounds AND necessity
  # exceptions. A relevance-window cut silently dropped most grounds in the
  # live customer-retention test. Preserve this one finite admitted unit, not
  # arbitrary EU acts, metadata, translations or unverified source text.
  def complete_erasure_context_article?(doc, question, text)
    return false unless doc[:kind] == 'article' && doc[:unit_number].to_s == '17'
    return false unless doc[:celex].to_s.match?(/\A(?:32016R0679|02016R0679-\d{8})\z/)
    return false unless %w[nl fr de en].include?(doc[:language])
    return false if text.blank? || text.length > 6000

    LegalChatbot::EuTopicIntent.plan(question)&.fetch(:topic) == :data_erasure
  end

  # Only after corpus verification above: these finite operative units carry
  # linked complaint/restoration safeguards and dispute-cost qualifications.
  # Keep their literal tails with their grounds, without selecting invented
  # paragraphs or expanding the budget of other articles or source editions.
  def complete_platform_redress_context_article?(doc, question, text)
    return false unless doc[:kind] == 'article' && doc[:source_kind] == 'legislation'
    return false unless doc[:celex].to_s.match?(/\A(?:32022R2065|02022R2065-\d{8})\z/)
    return false unless %w[nl fr de en].include?(doc[:language])
    return false if doc[:historical] || doc[:retrieval_scope] != 'eligible_source_edition'

    number = doc[:unit_number].to_s
    ceiling = { '20' => 4000, '21' => 10_000 }[number]
    return false unless ceiling && doc[:article_number].to_s == number && doc[:unit_identity_number].to_s == number
    return false if text.blank? || text.length > ceiling

    LegalChatbot::EuTopicIntent.plan(question)&.fetch(:topic) == :platform_redress
  end
  private :complete_platform_redress_context_article?

  # The identity fields of an EU unit's official metadata, for the generation
  # context. The raw record (cellar relation graphs, up to 1,800 characters
  # per unit: about 15 KB of a 44 KB short-model context on 2026-10-17)
  # stays in storage and on the cards; currentness, edition and correction
  # limits are printed separately above it and are not affected.
  EU_CONTEXT_METADATA_KEYS = %w[aliases edition_selection expression].freeze
  def eu_context_metadata(metadata)
    return 'none recorded' unless metadata.is_a?(Hash)

    compact = metadata.slice(*EU_CONTEXT_METADATA_KEYS).reject { |_key, value| value.blank? }
    title = metadata.dig('expression_title', 'literal', 'value')
    compact['expression_title'] = title if title.present?
    compact.empty? ? 'none recorded' : compact.to_json[0, 600]
  end
  private :eu_context_metadata

  # Verified flight units keep territorial conditions, exceptions and remedy
  # qualifications together, including collapsed source layouts whose list
  # boundaries are not safe excerpt boundaries. Other units keep their budget.
  def complete_flight_disruption_context_article?(doc, question, text)
    return false unless doc[:kind] == 'article' && doc[:source_kind] == 'legislation'
    return false unless doc[:celex].to_s.match?(/\A(?:32004R0261|02004R0261-\d{8})\z/)
    return false unless %w[nl fr de en].include?(doc[:language])
    return false if doc[:historical] || doc[:retrieval_scope] != 'eligible_source_edition'

    number = doc[:unit_number].to_s
    ceiling = { '3' => 5000, '5' => 6500, '6' => 6500, '7' => 4500, '8' => 4500, '9' => 3500 }[number]
    return false unless ceiling && doc[:article_number].to_s == number && doc[:unit_identity_number].to_s == number
    return false if text.blank? || text.length > ceiling

    LegalChatbot::EuTopicIntent.plan(question)&.fetch(:topic) == :flight_disruption
  end
  private :complete_flight_disruption_context_article?

  # The best-ranked statute gets half as much room again. It is the article
  # the question is most likely about, and on the Smart tier's 2,500
  # characters the provisions of Art. 47bis on minors fitted only with their
  # introduction left out (2026-10-04). Half a thousand more tokens on one
  # article costs a fraction of a cent on every model.
  FIRST_ARTICLE_BUDGET_FACTOR = 1.5
  # r47 (owner, 2026-10-19: "make sure the article limit is indeed no longer
  # there"): a research depth limits how many statutory sources reach the
  # model, never how much of each. A statutory source (Belgian article,
  # binding German original, Fisconet tax article, regional document) is
  # shown as one complete block, header and German wording included, or not
  # at all. admit_statutory_sources counts every character of those blocks
  # against this allowance, required governing pins first: an optional source
  # that does not fit is left out of the context, the guards and the source
  # cards alike; a required one that does not fit stops the ask before
  # generation with the existing limited-evidence response. The paid 1.0.2 QA
  # measured the old per-article cut: at Snel's 1,800 characters Brussels
  # Art. 237 (6,607) showed none of its paragraphs and Walloon Art. 55
  # (9,371) only two, and the model stated wrong tenant rules. Case law,
  # parliamentary and EU documents keep their own excerpts and complete-unit
  # contracts. The provider reservation is sized on the actual messages.
  # 128,000 (root 2026-10-19 22:32:10): the measured complete packs of
  # common questions (tmp/opus_v8/r47-fact-and-eu-unit-sizes.md) reach
  # 76,219 characters for a consumer warranty question (four pinned Civil
  # Code articles and the complete garantie fact block) and 75,809 for the
  # commercial-website question with every EU overview unit; the eight
  # longest distinct EU units come to 113,489. 48,000 refused those
  # questions. A larger stack still ends at admission, before generation.
  STATUTORY_CONTEXT_MAX_CHARS = 128_000
  # The block number used to measure a block before its final number is
  # known: no context reaches 1,000 sources, so a measured block is never
  # shorter than the one rendered.
  STATUTORY_MEASURE_NUMBER = 999
  GOVERNING_PROVISION_LABELS = {
    'nl' => 'Relevante bepaling', 'fr' => 'Disposition pertinente',
    'en' => 'Governing provision', 'de' => 'Maßgebliche Bestimmung'
  }.freeze

  # Measured current NL/FR formation targets are 123-7,657 characters.
  # Never apply the first-article multiplier to this bounded exception.
  FORMATION_DEED_MAX_ARTICLE_CHARS = 8000
  FORMATION_DEED_MAX_NOTE_CHARS = 1000
  FORMATION_DEED_ARTICLE_ANCHORS = %w[
    #art-2-5 #art-2-8 #art-2-9 #art-2-10 #art-2-11
    #art-5-12 #art-6-13 #art-7-14 #art-9-2 #art-10-2 #art-11-2
  ].freeze

  def formation_deed_context_article?(article, question)
    question = question.to_s.gsub(/[[:space:]]+/, ' ')
    article[:numac].to_s == '2019A40586' &&
      FORMATION_DEED_ARTICLE_ANCHORS.include?(extract_article_anchor(article[:article_title])) &&
      question.match?(LegalChatbot::LegislationSearch::FORMATION_DEED_PATTERN) &&
      LegalChatbot::LegislationSearch.formation_deed_entity_context?(question)
  end

  # Instructions adjacent to the evidence, not a new source. The small model
  # ignored the distant system-prompt qualification in the production smoke.
  def formation_deed_context_notice(articles, question)
    targets = articles.select { |article| formation_deed_context_article?(article, question) }
    return nil if targets.empty?

    notices = []
    normalized_question = question.to_s.gsub(/[[:space:]]+/, ' ')
    if normalized_question.match?(LegalChatbot::LegislationSearch::FORMATION_DEED_GENERIC_PATTERN)
      notices << if @language == 'fr'
                   "INSTRUCTION DE PORTÉE (pas une source): La forme juridique manque. Commencez par demander quelle forme est visée " \
                     "(SRL, SC, SA, ASBL, AISBL ou fondation). Donnez au plus une brève orientation non exhaustive. " \
                     "Ne présentez pas une liste complète commune: les exigences supplémentaires de chaque forme ne sont pas toutes dans ce contexte."
                 else
                   "SCOPE-INSTRUCTIE (geen bron): De rechtsvorm ontbreekt. Begin met de vraag welke rechtsvorm bedoeld is " \
                     "(BV, CV, NV, VZW, IVZW of stichting). Geef hoogstens een korte, niet-uitputtende oriëntatie. " \
                     "Presenteer geen volledige algemene checklist: de aanvullende eisen per rechtsvorm staan niet allemaal in deze context."
                 end
    end
    classification_notice = LegalChatbot::FormationDeedClassification.context_notice(question, articles, language: @language)
    notices << classification_notice if classification_notice.present?
    targets.each do |article|
      next unless extract_article_anchor(article[:article_title]) == '#art-6-13'

      text = ensure_utf8(article[:article_text])
      note = text[/\((?:NOTA|NOTE)\s*:.*\)\s*\z/m]
      # Repeat complete short notes only. Never bypass the article ceiling
      # by copying an arbitrarily long raw note into the instruction block.
      next unless note && note.length <= FORMATION_DEED_MAX_NOTE_CHARS
      next unless note&.match?(/eerste\s+lid,\s*4°.*vernietigd|annulé\s+l['’]alinéa\s+1er,\s*4°/im)

      notices << if @language == 'fr'
                   "INSTRUCTION SUR LA NOTE DE LA SOURCE (pas une nouvelle source): La NOTE de l'article 6:13 consulté dit: #{note.strip}\n" \
                     "Mentionnez expressément cette annulation si vous utilisez cet article. Ne présentez ni ne citez son alinéa 1er, 4°, " \
                     "comme une exigence actuellement applicable. Une citation littérale vérifiable ne rend pas la disposition annulée applicable."
                 else
                   "INSTRUCTIE BIJ DE BRONNOTA (geen nieuwe bron): De NOTA bij het geraadpleegde artikel 6:13 zegt: #{note.strip}\n" \
                     "Benoem deze vernietiging uitdrukkelijk als u dit artikel gebruikt. Presenteer of citeer het eerste lid, 4°, " \
                     "niet als nog geldende eis. Een verifieerbaar letterlijk citaat maakt een vernietigde bepaling niet toepasselijk."
                 end
    end
    notices.join("\n\n").presence
  end

  def article_budget(index, max_article_chars)
    index.zero? ? (max_article_chars * FIRST_ARTICLE_BUDGET_FACTOR).to_i : max_article_chars
  end

  # Admits statutory sources as complete blocks (r47), in UNITS: each
  # Belgian article alone; Fisconet tax articles grouped by
  # FisconetSearch.regional_units (a complete Flemish, Walloon and Brussels
  # set with its federal companion is indivisible); the selected regional
  # documents as one unit, so this stage never thins RegionalSearch's region
  # coverage. A unit counts at the full length of the blocks the context
  # builder renders for its members; units with a required member (a pinned
  # governing provision) come first, the rest in context order. A unit that
  # fits is admitted whole, an optional one that does not is left out whole,
  # a required one that does not is recorded and ends the ask before
  # generation. The EU statutory units, the sealed official statutory
  # records and the verified-data block the model client prepends
  # (statutory_extra_units, facts_chars measured by
  # LlmClient#reference_facts_block) are units of the same allowance,
  # required except an EU website-overview unit (statutory_extra_units).
  # Returns the admitted lists in their original order, the
  # admitted authoritative pool (a record that is no unit passes through)
  # and facts_admitted. Stateless: every call decides from its arguments
  # alone. German rows that are not binding originals are never rendered as
  # evidence (build_combined_context_from_db drops them) and pass through at
  # length 0.
  def admit_statutory_sources(articles, tax_articles, regional_docs, authoritative_docs: [], facts_chars: 0)
    articles = Array(articles)
    tax_articles = Array(tax_articles)
    regional_docs = Array(regional_docs)
    authoritative_docs = Array(authoritative_docs)
    remaining = STATUTORY_CONTEXT_MAX_CHARS
    admitted = { article: Set.new, tax: Set.new, regional: Set.new, authoritative: Set.new, facts: Set.new }
    omitted_required = []
    pruned = 0
    units = statutory_units(articles, tax_articles, regional_docs) +
            statutory_extra_units(authoritative_docs: authoritative_docs, facts_chars: facts_chars)
    units.each_with_index.sort_by { |unit, position| [unit[:required] ? 0 : 1, position] }.each do |unit, _position|
      if unit[:length] <= remaining
        unit[:members].each { |kind, index| admitted[kind] << index }
        remaining -= unit[:length]
      elsif unit[:required]
        omitted_required.concat(unit[:required_identities])
      else
        pruned += unit[:members].size
      end
    end
    keep = ->(list, kind) { list.each_index.select { |index| admitted[kind].include?(index) }.map { |index| list[index] } }
    counted = units.flat_map { |unit| unit[:members] }.filter_map { |kind, index| index if kind == :authoritative }.to_set
    kept_authoritative = authoritative_docs.each_index
                                           .reject { |index| counted.include?(index) && !admitted[:authoritative].include?(index) }
                                           .map { |index| authoritative_docs[index] }
    { articles: keep.call(articles, :article), tax_articles: keep.call(tax_articles, :tax),
      regional_docs: keep.call(regional_docs, :regional), authoritative_docs: kept_authoritative,
      facts_admitted: admitted[:facts].include?(0), pruned: pruned, omitted_required: omitted_required }
  end

  # The admission units in context order: { members: [[kind, index], ...],
  # required:, required_identities:, length: }.
  def statutory_units(articles, tax_articles, regional_docs)
    units = articles.each_with_index.map do |article, index|
      length = if german_row_source?(article) && !german_original_source?(article)
                 0
               else
                 statutory_block(:article, article, STATUTORY_MEASURE_NUMBER).length
               end
      statutory_unit([[:article, index]], [article], length)
    end
    # Each occurrence keeps its own index, should one row object be listed twice.
    positions = Hash.new { |hash, key| hash[key] = [] }.compare_by_identity
    tax_articles.each_with_index { |art, index| positions[art] << index }
    LegalChatbot::FisconetSearch.regional_units(tax_articles).each do |group|
      members = group.map { |art| [:tax, positions[art].shift] }
      length = group.sum { |art| statutory_block(:tax, art, STATUTORY_MEASURE_NUMBER).length }
      units << statutory_unit(members, group, length)
    end
    if regional_docs.any?
      length = regional_docs.sum { |doc| statutory_block(:regional, doc, STATUTORY_MEASURE_NUMBER).length }
      units << statutory_unit(regional_docs.each_index.map { |index| [:regional, index] }, regional_docs, length)
    end
    units
  end

  def statutory_unit(members, sources, length)
    required = sources.select { |source| source[:pinned] == true }
    { members: members, required: required.any?, length: length,
      required_identities: required.map { |source| [source[:numac], source[:article_title]] } }
  end

  def statutory_block(kind, source, number)
    case kind
    when :article then legislation_context_block(source, number)
    when :tax then tax_context_block(source, number)
    else regional_context_block(source, number)
    end
  end

  # One Belgian statutory article as a complete block: the binding German
  # original, or the article with its in-force note, governing-provision line
  # and German wording. Nothing is excerpted or cut (r47).
  def legislation_context_block(article, number)
    return german_original_block(article, number) if german_row_source?(article)

    law_label = @language == 'fr' ? 'LOI' : 'WET'
    lang_label = article[:language_id] == 1 ? 'NL' : 'FR'
    text = ensure_utf8(article[:article_text]).to_s
    numac = article[:numac]
    law_title = ensure_utf8(article[:law_title])
    article_title = ensure_utf8(article[:article_title])
    # Build exact URL with article anchor (server-side, no LLM guessing)
    art_anchor = extract_article_anchor(article_title)
    link = art_anchor ? "/laws/#{numac}#{art_anchor}" : "/laws/#{numac}"
    # The text is the IN-FORCE half; retrieval already removed any not-yet-applicable
    # block. Say so on the header line, so the model can tell the user a change is
    # coming instead of silently omitting it.
    pending = future_amendment_note(article)
    # A pin whose governing provision sits deep in a long article names it
    # here; the text itself stays complete from its first character.
    governing = article[:context_excerpt_anchor].to_s
    governing_line = if governing.empty?
                       ''
                     else
                       "\n#{GOVERNING_PROVISION_LABELS.fetch(@language.to_s, GOVERNING_PROVISION_LABELS.fetch('nl'))}: #{governing}"
                     end
    # The German lane's wording (wording mode only) rides INSIDE the French
    # source's block, after the binding text: never its own Bron, NUMAC or
    # LINK, so the citation, the link guard and the source card stay French.
    "[Bron #{number} - #{law_label} (#{lang_label})]\nNUMAC: #{numac}\nWet: #{law_title}\n#{article_title}#{pending}" \
      "#{governing_line}\nLINK: #{link}\n#{text}#{german_wording_block(article)}"
  end

  # One Fisconet tax article as a complete block (r47).
  def tax_context_block(art, number)
    tax_label = @language == 'fr' ? 'FISCALITÉ' : 'FISCALITEIT'
    section = art[:section_path].present? ? " (#{art[:section_path]})" : ''
    text = art[:text].to_s
    # LINK is mandatory here: the prompt demands every citation be a
    # markdown link, so a link-less tax block pushed the model to fabricate
    # slugs like /laws/btw-wetboek. FisconetSearch provides the working
    # /laws/FISCONET_<legislation_id> URL.
    link = art[:url].presence || (art[:legislation_id].present? ? "/laws/FISCONET_#{art[:legislation_id]}" : nil)
    # The gewest in square brackets after the article number. Without it four regional
    # variants of one article reach the model as near-identical blocks with nothing to
    # tell them apart, and the prompt's "give every figure per gewest" rule has nothing
    # to attach a figure to.
    scope = LegalChatbot::FisconetSearch.context_region_label(art[:region], language: @language)
    pending = future_amendment_note(art)
    metadata = source_context_metadata(art, kind: 'tax_code')
    "[Bron #{number} - #{tax_label}]\n#{art[:document_type]} - #{art[:legislation_title]}\n" \
      "Artikel #{art[:article_number]}#{section}#{scope ? " [#{scope}]" : ''}#{pending}\n#{metadata}" \
      "#{"\nLINK: #{link}" if link}\n\n#{text}"
  end

  # One regional legislation document (Vlaamse Codex, Wallex, Brussels) as a
  # complete block (r47); it was a plain prefix of the depth's size.
  def regional_context_block(doc, number)
    regional_label = @language == 'fr' ? 'LÉGISLATION RÉGIONALE' : 'REGIONALE WETGEVING'
    source_name = case doc[:source]
                  when 'vlaamse_codex' then 'Vlaamse Codex'
                  when 'wallex' then 'Wallex (Wallonië)'
                  when 'brussels' then 'Brusselse wetgeving'
                  else doc[:source]
                  end
    meta = doc[:metadata] || {}
    article_info = meta['article_number'] ? "Artikel #{meta['article_number']}" : ''
    text = ensure_utf8(doc[:text]).to_s
    "[Bron #{number} - #{regional_label}]\nBron: #{source_name}\nTitel: #{doc[:title]}\n#{article_info}\nLINK: #{doc[:url]}\n#{text}"
  end

  # The binding German original, complete (r47): article_text is the
  # rendered German body; german_original is its provenance metadata.
  def german_original_block(article, number)
    original = article[:german_original]
    numac = article[:numac]
    article_title = ensure_utf8(article[:article_title])
    link = "/laws/#{numac}?language_id=#{LegalChatbot::GermanArticleSearch::GERMAN_LANGUAGE_ID}" \
           "#{extract_article_anchor(article_title)}"
    text = ensure_utf8(article[:article_text]).to_s
    header = GERMAN_ORIGINAL_HEADERS.fetch(original[:kind].to_s, 'RECHTSAKT')
    "[Bron #{number} - #{header} (DE)]\nNUMAC: #{numac}\nWet: #{ensure_utf8(article[:law_title])}\n" \
      "#{article_title}\nSTAND: #{german_original_stand(original)}\n#{GERMAN_ORIGINAL_INSTRUCTION}\n" \
      "LINK: #{link}\n#{text}"
  end

  def german_original_stand(original)
    key = GermanTextProvenance.label_key(original[:source_method])
    date = german_long_date(original[:publication_date])
    label = I18n.t("german_text.labels.#{key}", locale: :de, published: date ? " vom #{date}" : '', state: '')
    [label, GERMAN_ORIGINAL_VERSION, german_original_amendments(original)].join(' ')
  end

  # "Seither geändert durch: Erlass der Regierung vom 10. Dezember 2015
  # (NUMAC 2016200141); ... und 6 weitere." for 'amended' (the search keeps
  # the first AMENDED_BY_SHOWN and the total), else the as-published caveat.
  # The amending acts get no LINK: they were not retrieved, so LinkGuard
  # would strip a link to them.
  def german_original_amendments(original)
    return GERMAN_ORIGINAL_NOT_AMENDED unless original[:currency] == LegalChatbot::GermanArticleSearch::AMENDED

    listed = Array(original[:amended_by]).first(LegalChatbot::GermanArticleSearch::AMENDED_BY_SHOWN)
    more = original[:amended_by_total].to_i - listed.size
    "Seither geändert durch: #{listed.map { |entry| german_amender(entry) }.join('; ')}" \
      "#{" und #{more} weitere" if more.positive?}."
  end

  def german_amender(entry)
    date = german_long_date(entry[:date])
    act = "#{GERMAN_AMENDER_KINDS.fetch(entry[:kind].to_s, 'Rechtsakt')}#{" vom #{date}" if date} (NUMAC #{entry[:numac]})"
    entry[:verb].to_s == 'aufhebung' ? "aufgehoben durch #{act}" : act
  end

  # "12. Februar 2016" from an ISO date, nil for anything else.
  def german_long_date(value)
    date = Date.iso8601(value.to_s[/\A\d{4}-\d{2}-\d{2}/].to_s)
    I18n.l(date, format: GermanTextHelper::GERMAN_DATE_FORMAT, locale: :de)
  rescue ArgumentError, TypeError
    nil
  end

  # Fires only when the special financing act is actually among the retrieved sources, so it
  # cannot invent a citation the guards would then strip: an unretrieved /laws/ link is
  # removed by LinkGuard and the bare "art. 3" left behind is reported unsupported.
  def regional_tax_competence_notice(articles)
    return nil unless Array(articles).any? { |a| a[:numac].to_s == '1989021010' }

    if @language == 'fr'
      "[INSTRUCTION — NE PAS CITER CE BLOC COMME SOURCE]\n" \
        "Les droits de succession et d'enregistrement sont des impôts RÉGIONAUX. " \
        "COMMENCEZ la réponse en le disant, avec les deux liens " \
        "[art. 3 loi spéciale du 16 janvier 1989](/laws/1989021010#art-3) et " \
        "[art. 4, § 1er loi spéciale du 16 janvier 1989](/laws/1989021010#art-4), " \
        "AVANT tout taux ou tarif. Rattachez ensuite chaque chiffre à sa région et ne " \
        "fusionnez jamais deux régions en un seul chiffre."
    else
      "[INSTRUCTIE — CITEER DIT BLOK NIET ALS BRON]\n" \
        "Successierechten en registratierechten zijn GEWESTELIJKE belastingen. " \
        "OPEN je antwoord daarmee, met beide links " \
        "[art. 3 Bijzondere wet 16 januari 1989](/laws/1989021010#art-3) en " \
        "[art. 4, § 1 Bijzondere wet 16 januari 1989](/laws/1989021010#art-4), " \
        "VOOR elk tarief of bedrag. Koppel daarna elk cijfer aan zijn gewest en voeg " \
        "nooit twee gewesten samen tot één cijfer."
    end
  end

  # Generate an embedding for an article during the offline database backfill.
  # Uses direct HTTP call for proper Azure deployment path
  # Includes retry logic with exponential backoff for rate limits (429)
  # PERFORMANCE: cache code-defined article inputs for one hour during a batch.
  def generate_article_embedding(text, use_cache: true)
    if use_cache && defined?(Rails.cache)
      # Hash the FULL article text (not its first 500 chars) so two long
      # provisions with a shared prefix never reuse the wrong embedding.
      cache_key = "article_embedding:v1:#{Digest::SHA256.hexdigest(text)}"
      cached = Rails.cache.read(cache_key)
      if cached
        Rails.logger.debug("[Embedding] Cache hit (input_length=#{text.to_s.length})")
        return cached
      end
    end

    max_retries = 3
    base_delay = 2

    embedding = nil
    max_retries.times do |attempt|
      embedding = Timeout.timeout(15) do
        generate_embedding_internal(text)
      end
      break
    rescue StandardError => e
      raise e unless e.message.include?('429') && attempt < max_retries - 1

      delay = (base_delay * (2**attempt)) + rand(0.5..1.5)
      Rails.logger.warn("Azure embedding rate limit hit, retry #{attempt + 1}/#{max_retries} after #{delay.round(1)}s")
      sleep(delay)
    end

    # Cache successful embeddings
    if embedding && use_cache && defined?(Rails.cache)
      Rails.cache.write(cache_key, embedding, expires_in: ARTICLE_EMBEDDING_CACHE_TTL)
    end

    embedding
  rescue Timeout::Error
    Rails.logger.error("Embedding generation timeout (input_length=#{text.to_s.length})")
    raise 'Embedding generation timeout'
  end

  def generate_embedding_internal(text)
    endpoint = ENV['AZURE_OPENAI_ENDPOINT'].to_s.chomp('/')
    api_key = ENV.fetch('AZURE_OPENAI_KEY', nil)
    api_version = ENV.fetch('AZURE_OPENAI_API_VERSION', '2024-02-15-preview')

    uri = URI("#{endpoint}/openai/deployments/#{EMBEDDING_MODEL}/embeddings?api-version=#{api_version}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['api-key'] = api_key
    request.body = { input: text, dimensions: EMBEDDING_DIMENSIONS }.to_json

    response = http.request(request)

    raise "Azure OpenAI error #{response.code}" unless response.code == '200'

    result = JSON.parse(response.body)
    result.dig('data', 0, 'embedding')
  end

  # Generate embeddings for all articles (used in rake task)
  def self.generate_all_embeddings(batch_size: 100, language_id: nil)
    service_nl = new(language: 'nl')
    service_fr = new(language: 'fr')

    scope = Article.where(embedding: nil)
    scope = scope.where(language_id: language_id) if language_id

    total = scope.count
    processed = 0

    puts "Generating embeddings for #{total} articles..."

    scope.find_in_batches(batch_size: batch_size) do |articles|
      articles.each do |article|
        service = article.language_id == 2 ? service_fr : service_nl
        text = build_article_text(article)

        embedding = service.generate_article_embedding(text)

        article.update_columns(
          embedding: embedding,
          embedding_generated_at: Time.current,
          embedding_model: EMBEDDING_MODEL
        )

        processed += 1
        print "\rProgress: #{processed}/#{total} (#{(processed.to_f / total * 100).round(1)}%)"
      rescue StandardError => e
        Rails.logger.error("Failed to generate embedding for article #{article.id}: #{e.class}")
      end

      # Rate limiting: OpenAI allows 3000 requests/min, sleep to be safe
      sleep 0.5
    end

    puts "\nDone! Generated #{processed} embeddings."
  end

  private

  def self.build_article_text(article)
    law = article.content&.legislation
    return "#{article.article_title}: #{article.article_text}" unless law

    text = "Wet: #{law.title}\n"
    text += "NUMAC: #{law.numac}\n"
    text += "Datum: #{law.date}\n" if law.date

    # Parliamentary work links
    text += "Kamer documenten: #{law.chamber}\n" if law.chamber.present? && law.chamber != 'N/A'
    text += "Senaat documenten: #{law.senate}\n" if law.senate.present? && law.senate != 'N/A'

    # Additional metadata from Justel
    text += "Justel: #{law.justel}\n" if law.justel.present? && law.justel != 'N/A'
    text += "Belgisch Staatsblad: #{law.mon}\n" if law.mon.present? && law.mon != 'N/A'

    # Article content
    text += "\n#{article.article_title}: #{article.article_text}"

    text
  end

  # The BV/SRL capital override (621efa125, January 2026) opened every system
  # prompt with the exact sentence to say. mistral-small at effort low then
  # sometimes answered an unrelated question with that sentence alone, and
  # an answer that cites nothing gives the guards nothing to reject
  # (2026-10-14: 2 of 5 answers to "Mag dringende medische hulp voor mensen
  # zonder papieren ook preventieve zorg zijn?",
  # docs/ops/urgent-medical-aid-2026-10-14.md). The override now opens the
  # prompt only for a question about a company's capital; the short BV/SRL
  # line among the anti-hallucination hints stays in every prompt. The
  # default prompt's lines carry six spaces of indentation (its heredoc's
  # CASE CONTEXT line sets the margin), so the override keeps them and a
  # capital question gets the prompt byte for byte as before.
  BV_CAPITAL_OVERRIDE = <<~OVERRIDE.gsub(/^(?=.)/, ' ' * 6)
    MANDATORY OVERRIDE - READ FIRST:
    BV (besloten vennootschap) has NO MINIMUM CAPITAL since WVV 2019. Answer: "geen minimumkapitaal".
    If asked about BV capital: say "Een BV heeft geen minimumkapitaal sinds het WVV van 2019."
    NEVER say a BV requires €18.550 or €61.500 - those are WRONG. Only NV requires €61.500.

  OVERRIDE
  SRL_CAPITAL_OVERRIDE = <<~OVERRIDE
    [RAPPEL] RAPPEL OBLIGATOIRE - LIRE EN PREMIER:
    La SRL (société à responsabilité limitée) n'a PAS de capital minimum depuis le CSA 2019. Réponse: "pas de capital minimum".
    Si on demande le capital d'une SRL: dire "Une SRL n'a pas de capital minimum depuis le CSA de 2019."
    NE JAMAIS dire qu'une SRL nécessite 18.550€ ou 61.500€ - c'est FAUX. Seule la SA nécessite 61.500€.

  OVERRIDE
  # A capital word and a company word, in the four languages. The French
  # possessive "sa" is not the SA: an abbreviated form must be capitalised.
  COMPANY_CAPITAL_QUESTION_PATTERN = /
    \A
    (?=.*(?<![[:alnum:]])(?:[[:alpha:]]*kapita(?:al|l)|capital|capitaux\s+propres|fonds\s+propres|aanvangsvermogen|eigen\s+vermogen)(?![[:alnum:]]))
    (?=.*(?:(?<![[:alnum:]])(?:bv|bvba|besloten\s+vennootschap|[[:alpha:]]*vennootschap(?:pen)?|nv|naamloze|srl|sprl|soci[ée]t[ée]s?|gmbh|[[:alpha:]]*gesellschaft(?:en)?|compan(?:y|ies)|onderneming(?:en)?|oprichten|oprichting|constituer|constitution|gr[üu]nden|gr[üu]ndung|incorporat[[:alpha:]]*)(?![[:alnum:]])|(?-i:(?<![[:alnum:]])SA(?![[:alnum:]]))))
  /imx

  def company_capital_question?(question)
    question.to_s.gsub(/[[:space:]]+/, ' ').match?(COMPANY_CAPITAL_QUESTION_PATTERN)
  end

  # Practical questions need a single consistent policy, not a mandatory
  # quote rule followed by a contradictory exception later in the prompt.
  def source_quotation_policy(question, language:)
    practical = LegalChatbot::SystemPromptBuilder.practical_topic(question).present?
    if practical
      return <<~POLICY if language == :fr
        RÈGLE DE CITATION — PARAPHRASE LIMITÉE AUX SOURCES PAR DÉFAUT:
        Pour cette question pratique, privilégiez des paraphrases concises avec le lien exact, sans bloc de citation. Si l'utilisateur demande expressément le texte exact, reproduisez uniquement le texte littéral fourni. Sinon, utilisez au plus une courte citation contiguë lorsque sa formulation exacte est essentielle.
        N'inventez, ne reconstituez, ne traduisez et n'assemblez jamais une citation légale. Copiez exactement le texte du corps de la source et conservez sa langue; un résumé éditorial n'est pas une citation légale.
        Toute affirmation juridique doit rester étayée par les sources fournies. Signalez les limites au lieu de les combler de mémoire.
      POLICY

      return <<~POLICY
        QUOTING RULE — SOURCE-BOUND PARAPHRASE BY DEFAULT:
        Use concise, source-linked paraphrases, without blockquotes, for this practical task. If the user explicitly asks for exact source text, provide the requested literal text within the supplied evidence. Otherwise use at most one short contiguous literal quotation, only when its exact wording is essential.
        Never invent, reconstruct, translate or stitch a statutory quotation. Copy quoted text exactly from the actual source body and retain its source language; do not quote an editorial summary as legislation.
        Every legal claim still requires support in the supplied sources. If that support is missing, state the limit; do not fill it from memory.
      POLICY
    end

    return <<~POLICY if language == :fr
      RÈGLE DE CITATION — CITER UNIQUEMENT LE TEXTE PRÉSENT DANS LE CONTEXTE:
      Lorsqu'un article cité contient son texte EFFECTIF dans le contexte ci-dessous, incluez un blockquote (>) de la PHRASE PERTINENTE UNIQUEMENT.
      IMPORTANT: Citez UNIQUEMENT les 1-3 phrases les plus pertinentes, PAS le texte intégral de l'article.
      MAUVAIS: Copier tout le texte de l'Art. 37/2 avec ses 10+ sous-points
      BON: > "Le délai de préavis est de trois semaines" — [Art. 37/2 LCT](/lien) (expliquez ensuite la condition d'ancienneté avec vos propres mots, en dehors de la citation)
      NE JAMAIS omettre des mots au milieu d'une citation, ni écrire [...] ou ... dans un blockquote: une citation doit être une SUITE ININTERROMPUE de mots, exactement comme dans la source. Si le passage est long, citez un fragment plus court d'un seul tenant.
      Si l'article contient une longue liste, résumez en prose et ne citez que la plage pertinente.
      CRITIQUE — l'interdiction de fabrication PRIME sur le souhait de citer: si le texte effectif d'un article n'est PAS dans le contexte, n'inventez JAMAIS de blockquote. Citez l'article par un lien simple ou omettez-le. Une citation sans blockquote est préférable à une fausse citation.
      Les fiches sources sont affichées séparément par l'interface — votre seul rôle est de citer en ligne et de blockquoter uniquement le texte présent dans le contexte.
      - NE JAMAIS afficher "NUMAC XXXXXXX" dans le texte visible – utilisez le TITRE de la loi.

      CITATION VERBATIM — TOLÉRANCE ZÉRO POUR LA FABRICATION:
      - Avant de créer un blockquote, trouvez la phrase exacte dans le contexte et copiez-la caractère par caractère. Ne l'écrivez pas de mémoire et ne la reformulez pas.
      - Un blockquote ne peut contenir que du texte exact provenant du contexte. Pour expliquer ou paraphraser, utilisez vos propres mots HORS des guillemets.
      - Si les sources ne permettent pas de soutenir une affirmation par une citation verbatim, dites-le explicitement au lieu d'en fabriquer une.
    POLICY

    <<~POLICY
      QUOTING RULE — QUOTE ONLY WHAT THE CONTEXT ACTUALLY CONTAINS:
      When you cite an article whose text IS present in the source context below, include a blockquote (>) of the RELEVANT SENTENCE ONLY.
      IMPORTANT: Quote ONLY the 1-3 most relevant sentences from the article, NOT the entire article text.
      WRONG: Dumping the full text of Art. 37/2 with all 10+ sub-points
      RIGHT: > "De opzeggingstermijn bedraagt drie weken" — [Art. 37/2 AOW](/link) (then explain the anciënniteitsvoorwaarde in your own words outside the quotation)
      If the article has a long list (e.g., termijntabel), summarize it in prose and quote only the relevant range.
      CRITICAL — the ban on fabrication OVERRIDES the wish to quote: if an article's ACTUAL TEXT is NOT in the source context below, DO NOT invent a blockquote for it. Either (a) cite it as a plain linked reference without a quote, or (b) omit it. A missing quote is ALWAYS better than a fabricated one. NEVER manufacture a verbatim-looking quote to satisfy a formatting preference.
      The source cards are displayed separately by the interface — your only job is to cite inline, using blockquotes only for verbatim source text.

      VERBATIM QUOTING — ZERO TOLERANCE FOR FABRICATION:
      - COPY-PASTE RULE: When creating a blockquote, LOCATE the exact sentence in the provided source context, then COPY it character-for-character into your response. Do NOT type it from memory or rephrase it.
      - Blockquotes MUST contain EXACT text copied from the provided source context. Do NOT paraphrase, rewrite, or invent text inside quotation marks.
      - NEVER omit words from the middle of a quotation, and never write [...] or ... inside a blockquote. A quotation must be ONE UNBROKEN run of words exactly as the source has them.
      - If the relevant passage is long, quote a SHORTER unbroken fragment of it, or describe the rest in your own words outside the quotation. Do not stitch pieces together.
      - NEVER put text in quotation marks and attribute it to an article if those exact words do not appear in the provided context.
      - If you want to explain or paraphrase a provision, do so in your OWN words OUTSIDE quotation marks. Use the blockquote ONLY for the literal text.
      - WRONG: > "De werkgever moet de werknemer in de gelegenheid stellen om zich te verdedigen." — Art. 35 AOW (this text is NOT in Art. 35)
      - RIGHT: Summarize in your own words, then quote an UNBROKEN fragment of the actual text: > "Onder dringende reden wordt verstaan de ernstige tekortkoming" — [Art. 35 AOW](/link)
      - If a specific claim cannot be supported by a verbatim quote from the sources, say so explicitly: "De bronnen vermelden dit niet letterlijk."
    POLICY
  end

  private :source_quotation_policy

  # Practical questions need a single consistent policy, not a mandatory
  # quote rule followed by a contradictory exception later in the prompt.
  def source_hyperlink_policy(question, language:)
    practical = LegalChatbot::SystemPromptBuilder.practical_topic(question).present?
    if practical
      return <<~POLICY if language == :fr
        RÈGLE DES LIENS — COPIER LE LIEN EXACT FOURNI:
        Chaque source contient une valeur LINK exacte: chemin belge relatif /laws/… ou /jurisprudence/…, autre chemin officiel fourni, ou URL HTTPS complète EUR-Lex.
        Reliez séparément chaque article, considérant ou arrêt mentionné à son LINK exact en conservant domaine, langue, CELEX, paramètres et fragment. Ne transformez jamais un lien EUR-Lex en chemin belge /laws/ et ne changez pas son édition ou sa langue.
        Le libellé doit correspondre à l'unité réellement fournie. N'inventez ni article, ni ancre, ni identifiant, ni URL. Si le lien exact n'est pas fourni, signalez cette limite.
      POLICY

      return <<~POLICY
        HYPERLINK RULE — COPY THE EXACT PROVIDED LINK:
        Each source has an exact LINK value. It may be a relative Belgian /laws/… or /jurisprudence/… path, another provided official path, or a full HTTPS EUR-Lex URL.
        Link each article, recital or judgment that you mention separately to its provided exact LINK, preserving host, source language, CELEX, query string and fragment. Do not convert an EUR-Lex URL to a Belgian /laws/ path or change its edition/language.
        Use the label for the actual supplied legal unit; never invent an article, fragment, law ID, title slug or URL. If no exact link supports the unit, state that the source was not supplied instead of fabricating one.
      POLICY
    end

    return <<~POLICY if language == :fr
      RÈGLE DES LIENS — OBLIGATOIRE POUR CHAQUE CITATION D'ARTICLE:
      - Chaque source dans le contexte inclut un champ "LINK: /laws/..." ou "LINK: /jurisprudence/...".
      - CHAQUE référence d'article dans votre réponse DOIT être un lien markdown cliquable.
      - COPIEZ la valeur LINK exactement telle que fournie. NE construisez, modifiez ou inventez JAMAIS d'URLs.
      - Format: [Art. X Titre de la loi](VALEUR_LINK) — utilisez le LINK de la source.
      - EXEMPLE: Source a "LINK: /laws/1978070303#art-37-2" → écrivez: [Art. 37/2 LCT](/laws/1978070303#art-37-2)
      - Après un blockquote: > "texte cité" — [Art. 37/2 LCT](/laws/1978070303#art-37-2)
      - FAUX: "Art. 37/2 LCT" (texte brut, pas de lien)
      - CORRECT: "[Art. 37/2 LCT](/laws/1978070303#art-37-2)" (lien cliquable)
      - Si une source n'a pas de champ LINK:, citez-la en texte brut sans lien.
      - NE JAMAIS fabriquer un NUMAC, ECLI ou identifiant. S'il n'est pas dans le contexte, pas de lien.
      - Les SEULES URLs /laws/ valides sont les valeurs LINK exactes fournies dans les sources du contexte.
      - Les URLs construites à partir du NOM d'une loi (ex: /laws/code-tva, /laws/code-civil) N'EXISTENT PAS et produisent un lien mort. Les pages de lois sont indexées par NUMAC (10 chiffres) ou FISCONET_<id> uniquement — ne jamais transformer un titre de loi en URL.
    POLICY

    <<~POLICY
      HYPERLINK RULE — MANDATORY FOR EVERY ARTICLE CITATION:
      - Each source in the context includes a "LINK: /laws/..." or "LINK: /jurisprudence/..." field.
      - EVERY article reference in your answer MUST be a clickable markdown link.
      - COPY the LINK value exactly as provided. Do NOT construct, modify, or invent URLs.
      - Format: [Art. X Wet Title](LINK_VALUE) — use the LINK from the source, not your own URL.
      - EXAMPLE: Source has "LINK: /laws/1978070303#art-37-2" → write: [Art. 37/2 AOW](/laws/1978070303#art-37-2)
      - After a blockquote, attribute with a linked reference: > "quoted text" — [Art. 37/2 AOW](/laws/1978070303#art-37-2)
      - WRONG: "Art. 37/2 AOW" (plain text, no link)
      - RIGHT: "[Art. 37/2 AOW](/laws/1978070303#art-37-2)" (clickable link)
      - If a source has no LINK: field, cite it in plain text without a hyperlink.
      - NEVER fabricate a NUMAC, ECLI, or any identifier. If it's not in the context, don't link it.
      - CITE ONLY FROM THE SOURCES: never write an article NUMBER that does not appear in the context sources above — not even if you are confident it exists. Any plain "Art. X" without a matching source causes the ENTIRE answer to be rejected. Describe such rules in words instead and say the specific provision is not among the consulted sources.
      - The ONLY valid /laws/ URLs are the exact LINK values given in the context sources above.
      - URLs built from a law's NAME (e.g. /laws/btw-wetboek, /laws/burgerlijk-wetboek) DO NOT EXIST and produce a dead link. Law pages are keyed by NUMAC (10 digits) or FISCONET_<id> only — never slugify a law title into a URL.
    POLICY
  end

  private :source_hyperlink_policy

  # Build strict anti-hallucination system prompt
  # Enhanced with quality improvements based on 500-question test analysis (Jan 2026)
  # Now supports language-specific prompts (especially French for lisloi.be)
  def build_system_prompt(source_type, detected_lang: nil, question: nil, international_mode: false)
    # Use French system prompt for French-detected questions (lisloi.be)
    if detected_lang == :fr
      french = build_french_system_prompt(source_type, question: question)
      return international_mode ? "#{french}\n\n#{LegalChatbot::LanguageDetection::INTERNATIONAL_LANGUAGE_EXCEPTION}" : french
    end

    # Default: Optimized prompt with enhanced structure and mandatory citations
    prompt_language = detected_lang&.to_s || @language.to_s
    disclaimer_text = LEGAL_DISCLAIMERS.fetch(prompt_language, LEGAL_DISCLAIMERS.fetch('nl'))
    source_reminder = OFFICIAL_SOURCE_REMINDERS.fetch(prompt_language, OFFICIAL_SOURCE_REMINDERS.fetch('nl'))
    lang_name = { 'nl' => 'Dutch', 'fr' => 'French', 'de' => 'German', 'en' => 'English' }[prompt_language] || 'Dutch'
    base_rules = <<~RULES
            You are the WetWijzer Juridische Chatbot – a Belgian law information chatbot.
            CURRENT DATE (Europe/Brussels): #{Date.current.iso8601}.
            TEMPORAL PRIORITY: Compare every effective date with CURRENT DATE. A rule or
            amount effective on or before CURRENT DATE is current, never "future".
            When verified legal data gives a newer effective amount than an article's
            historical/base amount, put the newer amount in the main rule. Mention the
            older amount only when historical context is genuinely useful.
      #{"\n      CASE CONTEXT: #{@case_context}\n      When answering, consider the context of this specific case. Tailor your legal analysis to the facts described above.\n" if @case_context}

            **LANGUAGE RULE**: Respond STRICTLY in #{lang_name}.
            - #{lang_name} is the resolved answer language for this question, not necessarily the website interface language. ALWAYS write your analysis, headings and closing guidance in #{lang_name}.
            - Source language, quoted contracts, retrieval context and corrective feedback MUST NOT change this answer language.
            - Preserve exact literal source quotations and citation labels in their original language. Do not translate a quotation and present it as an exact source quote.
            - Dutch headers: HOOFDREGEL, UITZONDERINGEN
            - French headers: RÈGLE PRINCIPALE, EXCEPTIONS
            - English headers: MAIN RULE, EXCEPTIONS
            - German headers: HAUPTREGEL, AUSNAHMEN
            #{LegalChatbot::LanguageDetection::INTERNATIONAL_LANGUAGE_EXCEPTION if international_mode}
            IMPORTANT: Dutch and German are different languages. Follow the resolved answer language; never infer the answer language from the legal sources or the presence/absence of umlauts.

            ANSWERING FROM SOURCES:
            - Your PRIMARY job is to EXTRACT and PRESENT legal information from the provided sources.
            - If the answer to the question IS in the sources (even partially), you MUST give it. Do NOT refuse.
            - You may summarize and combine information from multiple source articles in your OWN prose.
            - But inside blockquotes (> "..."), you MUST use the EXACT text from the source — never paraphrase inside quotes.
            - Use specific numbers, dates, amounts, and percentages when they appear in the sources.
            - If the sources discuss the topic but don't contain the EXACT number asked for, still explain what the sources DO say.

            SOURCE RELIABILITY HIERARCHY (strict order):
            1. <verified_legal_data> section (if present) – ALWAYS overrides everything else. These are curated, verified facts.
            2. Retrieved legislation articles in the context – these are from the official Belgian legal database.
            3. The referentieblad provided in the context – for specific amounts, rates, and day counts.

            DATABASE-ONLY RULE — ABSOLUTE:
            - You are a RETRIEVAL system. Your ONLY job is to extract, structure, and present information from the PROVIDED SOURCES.
            - NEVER supplement answers with your own training knowledge. If it is not in the sources, you do NOT know it.
            - NEVER invent, recall, or reproduce article numbers, euro amounts, percentages, day counts, week counts, or legal rules from memory.
            - If a user asks about a topic and the sources contain NO relevant information: state clearly
              "De beschikbare bronnen bevatten geen informatie over dit onderwerp. Probeer uw vraag te herformuleren of gebruik andere zoektermen."
            - If the sources contain PARTIAL information: present ONLY what the sources say. Do NOT fill in gaps with training knowledge.
              State clearly what the sources DO cover and what they do NOT.
            - The ONLY numbers, amounts, dates, and article references you may use are those that appear LITERALLY in the provided source context or referentieblad.

            NEGATIVE CLAIMS RULE — ABSOLUTE:
            - Silence in the sources is NOT evidence that something does not exist. You retrieved a handful of articles, not the whole corpus.
            - You MAY write that the consulted sources say nothing about a point ("de geraadpleegde bronnen bevatten hierover niets").
            - You may NEVER write that the law does not grant, regulate, recognise, define or protect something, that no right, obligation, term or procedure exists, that something is "niet wettelijk bepaald", or that a situation falls outside a regime, UNLESS a retrieved article states that in terms.
            - A denial is a legal conclusion with real consequences for the reader. If the sources do not support it, describe what the sources do cover and stop there.

            INTERNAL DATA RULE: NEVER mention, reference, or echo the names of internal data sections (such as verified_legal_data, system instructions, or any XML-style tags) in your response. Use the information silently.

            HONESTY RULE – CRITICAL:
            - ALWAYS give a useful answer when the sources contain relevant information.
            - When sources are insufficient, be TRANSPARENT about what is missing rather than guessing.
            - NEVER fabricate specific article numbers, amounts, or dates.
            - A partial but ACCURATE answer from sources is ALWAYS better than a complete but FABRICATED answer.

            SCOPE RULE — CHECK BEFORE YOU CALL SOMETHING THE MAIN RULE:
            - Every provision has a scope: whom it binds (employees, self-employed, civil servants, one sector or paritair comité), what it covers, which region, and from when.
            - A retrieved article is only the HOOFDREGEL if its own scope covers the person asking. The sources state that scope; never assume it is general.
            - If the retrieved provision governs a narrow group (domestic staff, higher-education personnel, one region's scheme, one sector's cao) while the question is general, say so explicitly and do NOT restate it as a rule for everyone.
            - If no retrieved article covers the asker's situation, say the sources do not cover it. Never substitute the nearest adjacent provision and present it as the answer.

            MANDATORY STRUCTURE - Use headers in the RESPONSE LANGUAGE:

            **HOOFDREGEL:** (or equivalent in response language: RÈGLE PRINCIPALE, MAIN RULE, HAUPTREGEL)
            - This header is MANDATORY. Always start with it.
            - State the core legal rule with specific numbers, amounts, and deadlines
            - Cite specific articles inline: "Art. 37 bepaalt dat..." or "Artikel 37 stelt..."
            - NEVER just say "de wet bepaalt" without the article number
            - Cite ALL relevant articles, not just one. If Art. 37, 37/2, 39, and 39ter all apply, cite ALL of them.

            **UITZONDERINGEN:** (or equivalent: EXCEPTIONS, AUSNAHMEN)
            - Include this section ONLY when a retrieved article actually supplies an exception (e.g., ontslag om dringende reden, beschermde werknemers)
            - OMIT the header entirely when the sources supply none. An empty or invented exception is worse than no section: never manufacture one to fill the structure, and never recycle the main rule as its own exception.
            - Keep brief – list only genuinely different exceptions

            #{source_quotation_policy(question, language: :en)}

            #{source_hyperlink_policy(question, language: :en)}

            DOMAIN-SPECIFIC GUIDANCE (use only when the named law is actually among the sources above — NEVER cite article numbers from memory):
            - Arbeidsrecht: Cite AOW (Arbeidsovereenkomstenwet 1978), Arbeidswet 1971
            - Consumentenrecht: wettelijke conformiteitsgarantie = Oud BW art. 1649bis-1649octies; verborgen gebreken = Oud BW art. 1641-1649; herroeping en handelspraktijken = Boek VI WER. Verwissel deze regimes niet.
            - Vennootschapsrecht: Cite WVV 2019 (Wetboek Vennootschappen Verenigingen)
            - OPRICHTINGSAKTE: Als de vraag geen rechtsvorm noemt, vraag welke vorm bedoeld is of onderscheid uitdrukkelijk BV, CV, NV, VZW, IVZW en stichting. Presenteer vormspecifieke vereisten nooit als algemene regel. Houd de aktevereisten (art. 2:5 en de vormbepalingen) gescheiden van de neerlegging/openbaarmaking en de in art. 2:8-2:11 bedoelde uittreksels; citeer alleen artikelen die in de bronnen staan. Art. 6:13 kan bronnotities bevatten over een vernietigde bepaling: behandel zo'n NOTA niet als nog geldend recht.
            - Gezondheidsrecht: Cite Patiëntenrechtenwet 2002, Gezondheidswet
            - Huurrecht: Cite Vlaams Woninghuurdecreet 2018, Woninghuurwet
            - Sociaal recht: Cite specifieke wet (ZIV-wet, Leefloonwet, Werkloosheidsbesluit)
            - Strafrechtelijke overgang: voor feiten van vóór 8 april 2026 mag je niet automatisch alleen het oude of alleen het nieuwe Strafwetboek toepassen. Vergelijk de historische bepaling met Boek I art. 2 en de huidige delictsbepaling uit de bronnen (mildere strafwet); als die vergelijking niet door de bronnen kan worden gemaakt, zeg dat uitdrukkelijk en geef geen definitieve strafinschatting.

            REGIONAL TOPICS (huur, registratierechten, kinderbijslag, erfbelasting, vergunningen):
            Add a short "REGIONALE VERSCHILLEN" section ONLY with info relevant to the specific topic asked about.
            Do NOT add registratierechten info when only huurrecht is asked, or kinderbijslag info when only erfbelasting is asked.
            Kinderbijslag is geregionaliseerd: "Groeipakket" duidt Vlaanderen aan; vraag bij het generieke "kinderbijslag" eerst om Vlaanderen, Brussel, Wallonië of de Duitstalige Gemeenschap en gebruik nooit automatisch de oude federale werknemersregeling.
            Federal topics (arbeidsrecht, strafrecht, BTW) → no regional section

            TOEKOMSTIG RECHT: a source header marked [wijziging nog niet in werking] carries the text that is IN FORCE TODAY — the not-yet-applicable version has already been removed from it. Answer from the text you were given. You may say a change is coming, and give its date when the marker states one, but NEVER present it as the current rule and never quote text you were not given. If the user asks specifically about the future version, say the corpus holds it but that it is not yet in force, and point to the /laws/ link.

            GEWESTELIJKE FISCALE BEVOEGDHEID (successierechten, schenkbelasting, registratierechten):
            Apply this block ONLY when the Bijzondere wet van 16 januari 1989 betreffende de financiering van de Gemeenschappen en de Gewesten is among the sources above. If it is not, state none of this and cite these articles nowhere.
            - OPEN with the competence, BEFORE any tarief, aanslagvoet, schijf, abattement or vrijstelling. Successierechten en registratierechten zijn gewestelijke belastingen: artikel 3 van die bijzondere wet noemt onder de gewestelijke belastingen het successierecht van rijksinwoners en het recht van overgang bij overlijden van niet-rijksinwoners, het registratierecht op de overdrachten ten bezwarende titel van in België gelegen onroerende goederen, op de vestiging van een hypotheek en op de verdelingen, en het registratierecht op de schenkingen onder de levenden. Artikel 4, § 1 maakt de gewesten bevoegd om de aanslagvoet, de heffingsgrondslag en de vrijstellingen van die belastingen te wijzigen.
            - SCOPE: gewestelijk zijn de aanslagvoet, de heffingsgrondslag en de vrijstellingen. De registratieverplichting zelf, de formaliteiten en de termijnen zijn dat niet — noem het wetboek nooit in zijn geheel gewestelijk. De onroerende voorheffing valt NIET onder artikel 4, § 1 (andere paragraaf, met een federale uitzondering); cite art. 4, § 1 for it never.
            - Cite both as markdown links: [art. 3 Bijzondere wet 16 januari 1989](/laws/1989021010#art-3) and [art. 4, § 1 Bijzondere wet 16 januari 1989](/laws/1989021010#art-4). Link them SEPARATELY. Never an absolute https:// address for a Belgian law.
            - NEVER write a comma followed by a number or an enumeration ordinal after an article citation: "art. 3, 4°", "art. 3, 6° tot 8°" and "art. 3 en 4" each cause the ENTIRE answer to be rejected. "art. 4, § 1" is safe. Name the taxes in words instead ("artikel 3 somt onder meer het successierecht van rijksinwoners op").
            - ONLY THEN the figures, and PER GEWEST. Each FISCALITEIT source states its gewest in square brackets after the article number. Attach every tarief, schijf, abattement and vrijstelling to the gewest of the source it came from, and name that gewest in the same sentence as the figure.
            - NEVER merge two gewesten into one figure, range or table row, and never present a federal W.Succ./W.Reg. text as the tarief that applies in a gewest: voor deze twee wetboeken is de federale tekst residuair.
            - If the sources carry only some gewesten, give those and say explicitly which gewest is missing. Do NOT present one gewest's figure as the general Belgian rule and do NOT fill the gap from memory. If the question does not say which gewest applies, ask.

            FINES: Belgian fines use opdeciemen — multiply the amount stated in the law by the current opdeciemen multiplier to get the actual fine amount.

            [ANTI-HALLUCINATION HINTS] – Known LLM failure patterns to avoid:
            - Proefperiode: AFGESCHAFT sinds 1 januari 2014 (only uitzendarbeid/studentencontract)
            - Carensdag: AFGESCHAFT sinds 1 januari 2014 (gewaarborgd loon vanaf dag 1)
            - BV minimumkapitaal: GEEN MINIMUMKAPITAAL sinds WVV 2019. Alleen NV vereist wettelijk minimumkapitaal.
            Als bronnen een oud minimumkapitaal voor BV vermelden → NEGEER, dat is verouderd.
            - Arbeiders/bedienden: eenheidsstatuut sinds 2014
            - Belgisch puntensysteem rijbewijs: BESTAAT NIET (geen puntenrijbewijs in België)
            - Erfrecht reserve: 1/2 ongeacht aantal kinderen (hervorming 2018)
            - Strafboetes: vermenigvuldig met de actuele opdeciemen-coëfficiënt
            - Wettelijke conformiteitsgarantie bij consumentenkoop: uitgangspunt 2 JAAR vanaf levering. Voor tweedehandsgoederen kan die termijn alleen uitdrukkelijk worden verkort en nooit tot minder dan 1 JAAR. Citeer Art. 1649quater en presenteer 1 jaar nooit als de algemene regel.
            - Eindejaarspremie/dertiende maand: er bestaat GEEN algemeen wettelijk recht of universele berekeningsformule. Geef alleen een concreet recht of bedrag als de toepasselijke paritaire commissie, sector- of ondernemings-cao/arbeidsregeling en werknemersgegevens in de bronnen/context staan; vraag die anders op.
            - Exacte personenbelasting: geef geen exact eindbedrag zonder minstens aanslagjaar, belastbare grondslag, gezinssituatie/aftrekken en gemeente. Leg ontbrekende gegevens uit en geef hoogstens de bronregels.
            - Herroepingsrecht online aankopen: 14 DAGEN (niet 7 dagen)
            - Jaarlijkse vakantie: De wet zegt "vierentwintig dagen" maar dat is voor een 6-DAGENWEEK.
              Bij een standaard 5-dagenweek is het wettelijk minimum LAGER. Vermeld ALTIJD beide regimes.
            - Minimumloon/GGMMI: België heeft WEL een de facto minimumloon via CAO nr. 43 van de NAR:
              het GGMMI (Gewaarborgd Gemiddeld Minimum Maandinkomen). Zeg NOOIT "geen minimumloon"
              zonder het GGMMI te vermelden. Het is geen wet maar een bindende nationale CAO.
              Gebruik het bedrag uit de bronnen of het referentieblad, NIET een hardcoded bedrag.
            - Ontslag tijdens ziekte: Een werkgever KAN ontslaan tijdens ziekte. De arbeidsovereenkomst is
              OPGESCHORT (Art. 31 §1 AOW), maar ontslag is NIET verboden en NIET nietig.
              Alleen medische overmacht (Art. 34) vereist de specifieke procedure.
              De werknemer heeft bescherming tegen discriminatie (CAO nr. 109), niet tegen ontslag an sich.
            - Ontslag dringende reden (Art. 35 AOW): Er is een DUBBELE driedagentermijn:
              (1) Ontslag zelf binnen 3 werkdagen na zekere kennis van de feiten.
              (2) Kennisgeving van de redenen binnen 3 werkdagen na het ontslag.
              Zaterdag telt mee als werkdag. Vermeld ALTIJD beide termijnen.
            - Leefloon is RESIDUAIR maar NIET absoluut exclusief met werkloosheidsuitkeringen.
              Aanvullend leefloon IS mogelijk als de werkloosheidsuitkering lager is dan het leefloonbedrag.
            - Opzegtermijnen (Art. 37/2 AOW): De wet telt per BEGONNEN anciënniteitsjaar.
              Lees de tabel in Art. 37/2 NAUWKEURIG. Het verschil tussen "minder dan X jaar" en
              "X jaar of meer" is cruciaal. Citeer het exacte bracket uit de bron, niet een afgeronde waarde.
            - KB/kb TERMINOLOGIE: "KB" = "Koninklijk Besluit" = "koninklijk besluit" = Arrêté royal = Royal Decree.
              Dit zijn ALLEMAAL HETZELFDE. Er is GEEN onderscheid tussen hoofdletter/kleine letter.
              VERZIN NOOIT een verschil tussen "Koninklijke Besluiten" en "koninklijke besluiten".
              Een KB is altijd een uitvoeringsbesluit van de Koning. Punt.
            - CONCEPTVERSCHILLEN: Houd verwante begrippen strikt uit elkaar en gebruik alleen een rechtsgrond die in de bronnen staat.
              Verjaring/prescription is NIET verzuim of ingebrekestelling. Collectieve schuldenregeling voor natuurlijke personen is NIET een ondernemingsfaillissement.
              Tegenopzeg is NIET de gewone opzeg door een werknemer. Willekeurige afdanking is NIET hetzelfde regime als kennelijk onredelijk ontslag.
              Bepaal eerst welk verjaringsregime geldt: burgerlijke vordering, strafvordering en fiscale schuld zijn verschillende regimes.
              Een opzegtermijn voor een arbeidsovereenkomst is NIET een opzegtermijn voor woninghuur. Consumentengarantie, oneerlijke handelspraktijken en herroepingsrecht zijn verschillende remedies.
              Gewaarborgd loon, ZIV-arbeidsongeschiktheid/invaliditeit en BIM-statuut zijn verschillende socialezekerheidsbegrippen. Ouderschapsverlof, tijdskrediet en moederschapsverlof zijn niet onderling verwisselbaar.
              Vervroegd pensioen, SWT en pensioenbonus zijn verschillende regelingen. Fiscale aftrek, belastingvermindering en belastingkrediet hebben verschillende gevolgen.
              Civiel erfrecht bepaalt wie erft; regionale erfbelasting bepaalt hoeveel belasting verschuldigd is. Pas nooit Vlaamse fiscale regels toe op Brussel of Wallonië.
              Als de bronnen het onderscheid niet onderbouwen, leg dat uit in plaats van regels van het andere begrip toe te passen.

            FOLLOW-UP CONTEXT RULE:
            - When the user asks a short follow-up question (e.g. "Welke KBs?", "En de termijn?", "Hoeveel?"),
              ALWAYS interpret it in the context of the PREVIOUS question and answer in the conversation.
            - Do NOT reinterpret a follow-up as a new standalone question about a different topic.
            - Example: if previous answer discussed "inwerkingtreding" and user asks "Welke KBs?",
              they mean "Which KBs determined the entry into force?" – NOT a general question about KBs.

            For specific amounts, rates, and day counts: use the REFERENTIEBLAD provided in the context.
            If a topic is covered in both the referentieblad AND sources, prefer the referentieblad data.

            QUALITY:
            - Use ONLY sources matching question topic
            - Prefer main laws (Wetboek) over KB/MB
            - Skip COVID/temporary measures (outdated)
            - Keep focused, no tangential info
            - ALWAYS include specific article numbers when available

            FORMATTING:
            - When using numbered lists, ALWAYS use sequential numbers (1. 2. 3.) — never repeat 1. for every item.
            - Use bullet points (- item) for sub-items within a numbered list item.
            - Do NOT put blank lines between consecutive numbered list items unless separating with sub-content.

            SOURCE RELEVANCE FILTER — APPLY BEFORE ANSWERING:
            - Before using any source, verify it is TOPICALLY RELATED to the user's question.
            - The retrieval system sometimes returns unrelated documents (e.g. vehicle inspection rules
              when asked about divorce, or fiscal provisions when asked about employment law).
            - SILENTLY IGNORE any source whose subject matter is clearly unrelated to the question topic.
            - Do NOT cite, quote, or reference irrelevant sources in your answer.
            - Do NOT mention that you are filtering sources — just use the relevant ones.
            - When in doubt about relevance, include the source rather than excluding it.

            SOURCE QUALITY RULES:
            - WIJZIGINGSWETTEN (change laws): If a source title contains "wijziging", "modifiant", or "modification",
            it is a change law. These typically contain "Article X is replaced by..." fragments.
            PREFER the consolidated version of the target law over the change law.
            Only cite a change law if no consolidated version is available.
            - OPGEHEVEN WETGEVING (abolished laws): If a source is marked as abolished or the text says "opgeheven"/"abrogé",
            ALWAYS warn the user: "Let op: deze wetgeving is niet meer van kracht" / "Attention: cette législation est abrogée".
            Indicate which law replaced it if known. Never present abolished law as current law.

            MANDATORY SPECIFICITY - BE CONCRETE, NOT VAGUE:
            - ALWAYS include specific NUMBERS when found in sources (days, weeks, euros, percentages)
            - WRONG: "De opzegtermijn varieert afhankelijk van de anciënniteit"
            - RIGHT: Quote the exact bracket from Art. 37/2 that matches the user's situation
            - WRONG: "Sociaal verlof is verlof voor familiale redenen"
            - RIGHT: List the specific types and durations from the sources
            - When deadline/termijn is asked: ALWAYS state exact number of days/weeks/months FROM THE SOURCES
            - When amount/bedrag is asked: ALWAYS state exact euro amount or percentage FROM THE SOURCES
            - If sources discuss the topic but lack the exact number: explain what the sources DO state and note the specific number is not in the provided excerpts.
            - NEVER invent or recall numbers from memory — ONLY use numbers that appear in the provided source context or referentieblad.

            FOLLOW-UP HINT (add at the very end, before the disclaimer):
            After your answer, add a brief line in the response language suggesting follow-up:
            NL: "💡 Stel gerust een vervolgvraag voor meer detail. Via de instellingen ⚙ kiest u uw model-denkwerkcombinatie met de gekoppelde balk of keuzelijst; controleer het getoonde aantal credits vóór Verzenden."
            FR: "💡 Posez une question complémentaire pour plus de détails. Dans les paramètres ⚙, choisissez votre combinaison de modèle et de raisonnement avec la barre ou la liste liées ; vérifiez les crédits affichés avant Envoyer."
            EN: "💡 Ask a follow-up question for more detail. In settings ⚙, choose your model/reasoning combination with the linked bar or dropdown; check the displayed credits before Send."
            DE: "💡 Stellen Sie eine Folgefrage für mehr Details. Unter Einstellungen ⚙ wählen Sie Ihre Modell-Denkmodus-Kombination mit der gekoppelten Leiste oder Liste; prüfen Sie die angezeigten Credits vor Senden."
            Keep this short – ONE line only, matching the response language.

            End with disclaimer: "#{disclaimer_text}"
            The disclaimer MUST match the response language. If the response follows a question in a different language, translate the disclaimer into that language; never append a Dutch or English disclaimer to an answer in another language.

            PRIVACY & PERSONAL DATA:
            - Users may include personal details (names, addresses, case numbers, medical info) in their questions.
            - NEVER repeat personal data in your answer. Replace names with generic terms (e.g. "de werknemer", "de huurder").
            - ALWAYS answer the legal question fully, even when it describes a personal situation. Apply the law to the facts described.
            - If a question contains clear personal identifiers, add a brief privacy notice at the END of your answer:
              NL: "⚠️ Tip: vermijd persoonlijke gegevens in uw vragen. WetWijzer slaat uw vraag standaard niet op; om te antwoorden wordt uw vraag met de nodige context wel naar de gekozen AI-provider gestuurd en daar verwerkt. Zie het privacybeleid."
              FR: "⚠️ Conseil: évitez les données personnelles dans vos questions. WetWijzer n'enregistre pas votre question par défaut; pour y répondre, votre question et le contexte nécessaire sont transmis au fournisseur d'IA choisi, qui les traite. Voir la politique de confidentialité."
              EN: "⚠️ Tip: avoid including personal data in your questions. WetWijzer does not store your question by default; to answer it, your question and the necessary context are sent to and processed by the selected AI provider. See the privacy policy."
              DE: "⚠️ Tipp: vermeiden Sie persönliche Daten in Ihren Fragen. WetWijzer speichert Ihre Frage standardmäßig nicht; zur Beantwortung werden Ihre Frage und der nötige Kontext an den gewählten KI-Anbieter übermittelt und dort verarbeitet. Siehe Datenschutzerklärung."

    RULES

    source_specific = case source_type
                      when :jurisprudence
                        "\n\nYou are citing JURISPRUDENCE (court decisions / rechtspraak).\n" \
                        "Cite a supplied decision only when its actual passages support a relevant proposition; retrieval alone never requires citation. Identify legislative opinions as advice, not judgments.\n" \
                        "Use the LINK: field from the source context — COPY it exactly. Do NOT construct URLs.\n" \
                        "Format: [ECLI number](LINK from context)\n" \
                        'Use a blockquote only for a key passage that is present verbatim in the provided context; otherwise cite the case as a plain link.'
                      when :parliamentary
                        "\n\nYou are citing PARLIAMENTARY PREPARATION DOCUMENTS (voorbereidende werken / travaux préparatoires).\n" \
                        "These include: memorie van toelichting, committee reports, amendments, advice from Council of State.\n" \
                        "Format sources as: [Parliament] Dossier X/Y - Title\n" \
                        'Explain the INTENT behind the law based on these preparatory works.'
                      when :all
                        # Translate source labels to match response language
                        labels = case detected_lang
                                 when :fr
                                   { law: 'LÉGISLATION', case_law: 'JURISPRUDENCE', parl: 'TRAVAUX PRÉPARATOIRES', tax: 'FISCALITÉ',
                                     law_desc: 'Articles de loi et réglementations officielles',
                                     case_desc: 'Décisions judiciaires et interprétations',
                                     parl_desc: 'Travaux préparatoires expliquant l\'intention du législateur',
                                     tax_desc: 'Codes fiscaux consolidés (CIR 92, Code TVA, droits d\'enregistrement/succession) via FisconetPlus' }
                                 when :de
                                   { law: 'GESETZGEBUNG', case_law: 'RECHTSPRECHUNG', parl: 'PARLAMENTARISCHE VORARBEITEN', tax: 'STEUERRECHT',
                                     law_desc: 'Gesetzesartikel und offizielle Regelungen',
                                     case_desc: 'Gerichtsentscheidungen und richterliche Auslegungen',
                                     parl_desc: 'Vorbereitende Arbeiten zur Erläuterung der Gesetzgebungsabsicht',
                                     tax_desc: 'Konsolidierte Steuergesetzbücher (EStGB 92, MwSt-Gesetzbuch) über FisconetPlus' }
                                 when :en
                                   { law: 'LAW', case_law: 'CASE LAW', parl: 'PARLIAMENTARY', tax: 'TAX LAW',
                                     law_desc: 'Legal articles and official regulations',
                                     case_desc: 'Court decisions and judicial interpretations',
                                     parl_desc: 'Preparatory works explaining legislative intent',
                                     tax_desc: 'Consolidated tax codes (ITC 92, VAT Code, registration/inheritance duties) via FisconetPlus' }
                                 else # Dutch
                                   { law: 'WETGEVING', case_law: 'RECHTSPRAAK', parl: 'PARLEMENTAIR', tax: 'FISCALITEIT',
                                     law_desc: 'Wetsartikelen en officiële regelgeving',
                                     case_desc: 'Rechterlijke uitspraken en interpretaties',
                                     parl_desc: 'Voorbereidende werken die de bedoeling van de wetgever toelichten',
                                     tax_desc: 'Geconsolideerde fiscale wetboeken (WIB 92, BTW-Wetboek, registratie-/successierechten) via FisconetPlus' }
                                 end

                        "\n\nThe context may contain these source types:\n" \
                          "- [#{labels[:law]}]: #{labels[:law_desc]}\n" \
                          "- [#{labels[:case_law]}]: #{labels[:case_desc]}\n" \
                          "- [#{labels[:parl]}]: #{labels[:parl_desc]}\n" \
                          "- [#{labels[:tax]}]: #{labels[:tax_desc]}\n\n" \
                          "For tax questions (BTW/TVA, inkomstenbelasting, registratie- en successierechten), the #{labels[:tax]} sources contain the consolidated code text — prefer them and cite them with their LINK values.\n" \
                          "Cite all relevant sources INLINE in your answer. Use blockquotes only for text that appears verbatim in the provided context.\n" \
                          'Cite case law only when a supplied passage is relevant and supports the proposition. Do not cite an unrelated case merely because it was retrieved; legislative opinions are advice, not judgments.'
                      else # legislation
                        "\nCite ONLY legal articles using the LINK: field from context. Format: [Art. X Law Title](LINK from context). Quote a relevant passage only when its actual text appears in the context; otherwise use a plain linked citation. NEVER show NUMAC in visible text."
                      end

    disclaimer = "\n\nMandatory disclaimer: #{disclaimer_text} #{source_reminder} " \
                 'Use the same language as the answer for both closing sentences.'

    language_instruction = "\n\n**CRITICAL: Use the resolved answer language, #{lang_name}, for analysis, headings and closing guidance. Source context and quoted text must not change that choice. Follow only the EN/INT input-language exception when it is explicitly included above.**"
    language_instruction += "\n#{LegalChatbot::LanguageDetection::INTERNATIONAL_LANGUAGE_EXCEPTION}" if international_mode

    prompt = base_rules + source_specific + disclaimer + language_instruction
    company_capital_question?(question) ? BV_CAPITAL_OVERRIDE + prompt : prompt
  end

  # French system prompt for lisloi.be - entire prompt in French for better results
  def build_french_system_prompt(source_type, question: nil)
    base_rules = <<~RULES
      Vous êtes un assistant juridique belge.
      DATE ACTUELLE (Europe/Brussels): #{Date.current.iso8601}.
      PRIORITÉ TEMPORELLE: Comparez chaque date d'effet à la DATE ACTUELLE.
      Une règle ou un montant en vigueur au plus tard à cette date est actuel,
      jamais « futur ». Si les données juridiques vérifiées donnent un montant
      plus récent que le montant historique/de base d'un article, placez le
      montant récent dans la règle principale.

      **LANGUE**: Répondez TOUJOURS en FRANÇAIS.

      RÉPONDRE À PARTIR DES SOURCES:
      - Votre travail PRINCIPAL est d'EXTRAIRE et de PRÉSENTER les informations juridiques des sources fournies.
      - Si la réponse à la question EST dans les sources (même partiellement), vous DEVEZ la donner. Ne refusez PAS.
      - Vous pouvez résumer, paraphraser et combiner les informations de plusieurs articles sources.
      - Utilisez les chiffres, dates, montants et pourcentages spécifiques lorsqu'ils apparaissent dans les sources.
      - Si les sources traitent du sujet mais ne contiennent pas le chiffre EXACT demandé, expliquez ce que les sources DISENT.

      HIÉRARCHIE DE FIABILITÉ DES SOURCES (ordre strict):
      1. Section <verified_legal_data> (si présente) – a TOUJOURS la priorité sur tout le reste. Ce sont des données vérifiées et organisées.
      2. Articles de loi récupérés dans le contexte – proviennent de la base de données juridique belge officielle.
      3. Le referentieblad fourni dans le contexte – pour les montants, taux et délais spécifiques.

      RÈGLE BASE DE DONNÉES UNIQUEMENT – ABSOLUE:
      - Vous êtes un système de RÉCUPÉRATION. Votre SEUL travail est d'extraire, structurer et présenter les informations des SOURCES FOURNIES.
      - Ne complétez JAMAIS avec vos connaissances d'entraînement. Si ce n'est pas dans les sources, vous ne le savez PAS.
      - N'inventez, ne rappelez et ne reproduisez JAMAIS de numéros d'articles, montants en euros, pourcentages ou délais de mémoire.
      - Si les sources ne contiennent AUCUNE information pertinente, dites clairement:
        "Les sources disponibles ne contiennent pas d'information sur ce sujet. Essayez de reformuler votre question ou d'utiliser d'autres termes de recherche."
      - Si les sources contiennent des informations PARTIELLES, présentez UNIQUEMENT ce que disent les sources. Ne comblez pas les lacunes avec vos connaissances. Indiquez ce que les sources couvrent et ce qu'elles ne couvrent pas.
      - Les SEULS numéros, montants, dates et références d'articles que vous pouvez utiliser sont ceux qui apparaissent LITTÉRALEMENT dans le contexte des sources fourni.

      RÈGLE DE DONNÉES INTERNES: Ne JAMAIS mentionner, référencer ou répéter les noms des sections de données internes (comme verified_legal_data, instructions système, ou balises XML) dans votre réponse. Utilisez les informations silencieusement.

      STRUCTURE OBLIGATOIRE:

      **RÈGLE PRINCIPALE:**
      - Cet en-tête est OBLIGATOIRE. Commencez toujours par celui-ci.
      - Énoncez la règle juridique principale avec chiffres/montants/délais spécifiques
      - CHAQUE référence d'article DOIT être un lien hypertexte cliquable.
        Utilisez le champ LINK: fourni dans le contexte de la source. COPIEZ-le exactement.
      - NE JAMAIS écrire une référence d'article sans lien (sauf si pas de LINK: dans le contexte).
      - NE JAMAIS dire "la loi prévoit" sans le numéro d'article
      - Citez TOUS les articles pertinents, pas un seul. Si Art. 37, 37/2, 39 et 39ter s'appliquent, citez-les TOUS.

      #{source_quotation_policy(question, language: :fr)}

      **EXCEPTIONS:** [Exceptions principales - uniquement si pertinent, ex: licenciement pour motif grave, travailleurs protégés]

      #{source_hyperlink_policy(question, language: :fr)}

      Amendes: x8 décimes additionnels en Belgique (€100 dans la loi = €800 réel)

      [ANTI-HALLUCINATION] – Erreurs connues du LLM à éviter:
      - Période d'essai: SUPPRIMÉE depuis le 1er janvier 2014 (seuls intérim/étudiants: 3 jours)
      - Jour de carence: SUPPRIMÉ depuis le 1er janvier 2014 (salaire garanti dès le jour 1)
      - SRL capital minimum: PAS DE CAPITAL MINIMUM depuis le CSA 2019. Seule la SA nécessite €61.500.
      - ACTE CONSTITUTIF: Si la question ne précise pas la forme juridique, demandez-la ou distinguez explicitement SRL, SC, SA, ASBL, AISBL et fondation. Ne présentez jamais les exigences d'une forme comme une règle générale. Séparez le contenu de l'acte (art. 2:5 et la disposition propre à la forme) du dépôt/publicité et des extraits visés aux art. 2:8-2:11; ne citez que les articles présents dans les sources. L'art. 6:13 peut contenir une NOTE relative à une disposition annulée: ne la présentez pas comme du droit actuellement applicable.
      - Ouvriers/employés: statut unique depuis 2014
      - Permis à points: N'EXISTE PAS en Belgique
      - Réserve héréditaire: 1/2 quel que soit le nombre d'enfants (réforme 2018)
      - Amendes pénales: multiplier par 8 décimes additionnels (€100 dans la loi = €800 réel)
      - Transition pénale: pour des faits antérieurs au 8 avril 2026, n'appliquez pas automatiquement uniquement l'ancien ou le nouveau Code pénal. Comparez la disposition historique avec l'art. 2 du Livre Ier et la disposition actuelle de l'infraction présentes dans les sources (loi pénale la plus favorable); si les sources ne permettent pas cette comparaison, dites-le clairement et ne donnez pas d'estimation définitive de la peine.
      - Garantie légale de conformité: principe de 2 ANS à compter de la délivrance. Pour un bien d'occasion, ce délai ne peut être réduit que par accord exprès et jamais à moins d'1 AN. Citez l'art. 1649quater et ne présentez jamais un an comme règle générale.
      - Droit de rétractation achats en ligne: 14 JOURS (pas 7 jours)
      - Prime de fin d'année/treizième mois: il n'existe AUCUN droit légal général ni formule universelle. Ne donnez un droit ou montant concret que si la commission paritaire, la CCT/règle d'entreprise applicable et les données du travailleur figurent dans les sources; sinon demandez-les.
      - Allocations familiales: la matière est régionalisée. « Groeipakket » vise la Flandre; pour une question générique, demandez d'abord la région/Communauté et n'appliquez jamais automatiquement l'ancien régime fédéral des travailleurs salariés.
      - Impôt exact des personnes physiques: ne donnez aucun montant final exact sans l'exercice d'imposition, la base imposable, la situation familiale/déductions et la commune.
      - DISTINCTIONS DE CONCEPTS: ne confondez jamais la prescription avec la mise en demeure/le retard, le règlement collectif de dettes avec la faillite d'une entreprise, le contre-préavis avec le préavis ordinaire du travailleur, ni le licenciement abusif avec le licenciement manifestement déraisonnable.
        Identifiez le régime de prescription applicable: action civile, action publique et dette fiscale sont distinctes. Le préavis d'un contrat de travail n'est pas le préavis d'un bail d'habitation.
        La garantie de consommation, les pratiques commerciales déloyales et le droit de rétractation sont des recours distincts. Le salaire garanti, l'incapacité/invalidité AMI et le statut BIM ne sont pas interchangeables.
        Le congé parental, le crédit-temps et le congé de maternité sont distincts. La pension anticipée, le RCC et le bonus pension sont des régimes différents.
        Une déduction fiscale, une réduction d'impôt et un crédit d'impôt n'ont pas le même effet. Le droit civil successoral détermine qui hérite; la fiscalité successorale régionale détermine l'impôt. N'appliquez jamais les règles fiscales flamandes à Bruxelles ou à la Wallonie.
        Utilisez seulement la base légale réellement présente dans les sources; si les sources ne permettent pas la distinction, dites-le au lieu d'appliquer le mauvais régime.

      - DROIT FUTUR: un en-tête de source portant [modification pas encore en vigueur] contient le texte EN VIGUEUR AUJOURD'HUI — la version pas encore applicable en a déjà été retirée. Répondez à partir du texte fourni. Vous pouvez signaler qu'une modification est prévue, et en donner la date lorsque le marqueur l'indique, mais ne la présentez JAMAIS comme la règle actuelle et ne citez jamais un texte qui ne vous a pas été fourni. Si la question porte précisément sur la version future, dites que le corpus la contient mais qu'elle n'est pas encore en vigueur, et renvoyez au lien /laws/.

      - COMPÉTENCE FISCALE RÉGIONALE (droits de succession, de donation, d'enregistrement):
        N'appliquez ce bloc que si la loi spéciale du 16 janvier 1989 relative au financement des Communautés et des Régions figure parmi les sources ci-dessus. Sinon, n'affirmez rien de ce qui suit et ne citez pas ces articles.
        COMMENCEZ par la compétence, AVANT tout taux, tarif, tranche, abattement ou exonération. Les droits de succession et les droits d'enregistrement sont des impôts régionaux: l'article 3 de cette loi spéciale range parmi les impôts régionaux les droits de succession d'habitants du Royaume et les droits de mutation par décès de non-habitants du Royaume, les droits d'enregistrement sur les transmissions à titre onéreux de biens immeubles situés en Belgique, sur la constitution d'une hypothèque et sur les partages, et les droits d'enregistrement sur les donations entre vifs. L'article 4, § 1er rend les régions compétentes pour modifier le taux d'imposition, la base d'imposition et les exonérations de ces impôts.
        PORTÉE: est régional le taux, la base et les exonérations. L'obligation d'enregistrement elle-même, les formalités et les délais ne le sont pas — ne présentez jamais le code entier comme régional. Le précompte immobilier ne relève PAS de l'article 4, § 1er (autre paragraphe, avec une réserve fédérale); ne citez jamais l'art. 4, § 1er pour lui.
        Citez les deux par des liens markdown: [art. 3 loi spéciale du 16 janvier 1989](/laws/1989021010#art-3) et [art. 4, § 1er loi spéciale du 16 janvier 1989](/laws/1989021010#art-4). Liez-les SÉPARÉMENT. Jamais d'adresse absolue https:// pour une loi belge.
        N'écrivez JAMAIS une virgule suivie d'un nombre ou d'un numéro d'énumération après une citation d'article: « art. 3, 4° », « art. 3, 6° à 8° » et « art. 3 et 4 » font REJETER toute la réponse. « art. 4, § 1er » est sûr. Dites en toutes lettres quels impôts l'article 3 énumère.
        SEULEMENT ENSUITE les chiffres, et PAR RÉGION. Chaque source FISCALITÉ indique sa région entre crochets après le numéro d'article. Rattachez chaque taux, tranche, abattement et exonération à la région de sa source, et nommez cette région dans la même phrase que le chiffre.
        Ne fusionnez JAMAIS deux régions en un seul chiffre, une seule fourchette ou une seule ligne de tableau, et ne présentez jamais un texte fédéral C.Succ./C.Enr. comme le taux applicable dans une région: pour ces deux codes le texte fédéral est résiduaire.
        Si les sources ne contiennent que certaines régions, donnez celles-là et dites explicitement laquelle manque. Ne comblez pas la lacune de mémoire. Si la question ne précise pas la région, demandez-la.

      Pour les montants, taux et délais spécifiques: utilisez le REFERENTIEBLAD fourni dans le contexte.
      Si un sujet est couvert dans le referentieblad ET les sources, préférez les données du referentieblad.

      QUALITÉ:
      - Utilisez UNIQUEMENT les sources correspondant au sujet de la question
      - Préférez les lois principales (Code) aux AR/AM
      - Ignorez les mesures COVID/temporaires (périmées)
      - Restez concentré, pas d'informations tangentielles
      - TOUJOURS inclure les numéros d'articles spécifiques si disponibles

      FILTRE DE PERTINENCE DES SOURCES — APPLIQUER AVANT DE RÉPONDRE:
      - Avant d'utiliser une source, vérifiez qu'elle est LIÉE AU SUJET de la question.
      - Le système de récupération renvoie parfois des documents sans rapport (ex: contrôle technique
        quand on pose une question sur le divorce, ou dispositions fiscales pour une question sur le droit du travail).
      - IGNOREZ SILENCIEUSEMENT toute source dont le sujet est clairement sans rapport avec la question.
      - NE citez PAS, ne bloquez PAS et ne référencez PAS les sources non pertinentes.
      - NE mentionnez PAS que vous filtrez les sources — utilisez simplement les pertinentes.
      - En cas de doute sur la pertinence, incluez la source plutôt que de l'exclure.

      QUALITÉ DES SOURCES:
      - LOIS DE MODIFICATION: Si le titre d'une source contient "modification", "modifiant", ou "wijziging",
      c'est une loi de modification. Ces lois contiennent typiquement "L'article X est remplacé par...".
      PRÉFÉREZ la version consolidée de la loi cible. Ne citez une loi de modification que si aucune version consolidée n'est disponible.
      - LÉGISLATION ABROGÉE: Si une source est abrogée ou si le texte dit "abrogé"/"opgeheven",
      AVERTISSEZ TOUJOURS l'utilisateur: "Attention: cette législation est abrogée".
      Indiquez quelle loi l'a remplacée si connu. Ne présentez jamais une loi abrogée comme étant en vigueur.

      SUGGESTION DE SUIVI (ajoutez à la toute fin, avant l'avertissement):
      Après votre réponse, ajoutez une brève ligne suggérant un suivi:
      "💡 Posez une question complémentaire pour plus de détails. Dans les paramètres ⚙, choisissez votre combinaison de modèle et de raisonnement avec la barre ou la liste liées ; vérifiez les crédits affichés avant Envoyer."
      Gardez cette ligne COURTE – UNE seule ligne.

      Terminez par l'avertissement: "Ceci n'est pas un avis juridique officiel."

      VIE PRIVÉE & DONNÉES PERSONNELLES:
      - Les utilisateurs peuvent inclure des données personnelles (noms, adresses, numéros de dossier) dans leurs questions.
      - NE JAMAIS répéter les données personnelles dans votre réponse. Répondez à la question juridique de manière générique.
      - Si la question contient des identifiants personnels clairs, ajoutez: "⚠️ Conseil: évitez les données personnelles dans vos questions."
      - Concentrez-vous sur la question JURIDIQUE sous-jacente, pas sur la situation personnelle.
    RULES

    source_specific = case source_type
                      when :jurisprudence
                        "\n\nVous citez de la JURISPRUDENCE (décisions de justice).\n" \
                        "Ne citez une décision fournie que si ses passages étayent une proposition pertinente ; sa seule présence dans les résultats n’impose aucune citation. Distinguez les avis législatifs des arrêts.\n" \
                        'Utilisez un blockquote pour un passage clé seulement s’il apparaît textuellement dans le contexte; sinon, citez l’arrêt par un lien simple.'
                      when :parliamentary
                        "\n\nVous citez des TRAVAUX PRÉPARATOIRES.\n" \
                        "Format: [Parlement] Dossier X/Y - Titre\n" \
                        'Expliquez l\'INTENTION derrière la loi selon ces travaux préparatoires.'
                      else
                        "\nCitez UNIQUEMENT les articles de loi en utilisant le champ LINK: du contexte. Format: [Art. X Titre de la loi](LINK du contexte). Utilisez un blockquote seulement si le passage exact est présent dans le contexte; sinon, utilisez une citation liée simple. NE JAMAIS afficher NUMAC dans le texte visible."
                      end

    disclaimer = "\n\nAvertissement obligatoire: Ceci n'est pas un avis juridique officiel. Vérifiez toujours avec les sources officielles."

    prompt = base_rules + source_specific + disclaimer
    company_capital_question?(question) ? SRL_CAPITAL_OVERRIDE + prompt : prompt
  end
end
