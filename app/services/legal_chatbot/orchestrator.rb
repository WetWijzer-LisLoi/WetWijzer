# frozen_string_literal: true

require 'securerandom'

module LegalChatbot
  # Thin orchestrator that coordinates the extracted service objects.
  # This module is included in LegalChatbotService to provide a clean
  # `orchestrated_multi_search` method that wires all services together.
  #
  # Architecture:
  #   ask → ask_internal_multi → orchestrated_multi_search
  #         ├── EmbeddingService.generate / generate_hyde
  #         ├── LegislationSearch.search   (FAISS + FTS5 keyword supplement + boosting)
  #         ├── JurisprudenceSearch.search  (FAISS → source DB metadata lookup)
  #         ├── ParliamentarySearch.search  (FAISS → SQLite metadata lookup)
  #         ├── FisconetSearch.search       (FAISS → SQLite metadata lookup)
  #         ├── RegionalSearch.search       (FAISS with inline metadata)
  #         ├── ContextBuilder.build_combined
  #         ├── LlmClient.query
  #         └── SourceFormatter.format_all
  module Orchestrator
    extend ActiveSupport::Concern

    # The fan-out moved to LegalChatbot::SearchFanOut (FBL-061); the alias
    # keeps the constant reachable at its long-standing name.
    PARALLEL_SEARCH_TIMEOUT_SECONDS = SearchFanOut::PARALLEL_SEARCH_TIMEOUT_SECONDS

    # Code-owned retrieval version (RAT-003). BUMP THIS whenever retrieval or
    # ranking behaviour changes - fan-out membership, context policy, reranking,
    # chunk selection, the citation-repair chain - so ratings gathered under
    # different retrieval are not silently averaged together as one
    # configuration. A version label, never a hash of retrieved content.
    RETRIEVAL_VERSION = 'retrieval_2026_08'

    included do
      # The phase this request is currently in, for the progress bar.
      #
      # Orchestration runs in a query thread while the controller writes the
      # SSE stream from the request thread, so the phase is published here and
      # POLLED rather than pushed: no callback has to be threaded through, and
      # a missed read costs a progress update, never the answer. Plain
      # assignment of an immutable value is atomic under MRI, so no lock.
      attr_reader :current_phase, :current_phase_attempt

      def publish_phase(phase, attempt: nil)
        @current_phase = phase
        @current_phase_attempt = attempt
      end

      # RAT-003. Read-only access to the effective generation trace of the LAST
      # provider call, for the analytics write path.
      #
      # Deliberately `@llm_svc&.` and not `llm_svc.`: reading must never
      # CONSTRUCT a client. A request that never reached a provider - cache
      # hit, guard rejection, early error - has no trace, and inventing an
      # empty one would let an untraced answer look traced.
      def generation_trace
        @llm_svc&.generation_trace
      end

      # How many provider generations this answer actually cost. 1 normally,
      # 2 or 3 when the citation guard rejected and regenerated.
      def provider_call_count
        @llm_svc&.provider_call_count
      end

      # Lazy-initialized service instances (thread-safe via instance vars)

      private

      def embedding_svc
        @embedding_svc ||= LegalChatbot::EmbeddingService.new(
          language: @language,
          mistral_api_key_env: @mistral_api_key_env
        )
      end

      def llm_svc
        @llm_svc ||= LegalChatbot::LlmClient.new(
          model_override: @model_override,
          language: @language,
          concise: @concise,
          case_context: @case_context,
          reasoning_effort: @reasoning_effort,
          profile: @profile || 'general',
          embedding_service: embedding_svc,
          mistral_api_key_env: @mistral_api_key_env
        )
      end

      def context_builder_svc
        @context_builder_svc ||= LegalChatbot::ContextBuilder.new(language: @language)
      end

      def source_formatter_svc
        @source_formatter_svc ||= LegalChatbot::SourceFormatter.new(language: @language)
      end

      def reference_sheets_svc
        @reference_sheets_svc ||= LegalChatbot::ReferenceSheets.new(
          language: @language,
          embedding_service: embedding_svc
        )
      end

      def legislation_search_svc
        @legislation_search_svc ||= LegalChatbot::LegislationSearch.new(
          language: @language,
          embedding_service: embedding_svc,
          context_numacs: @context_numacs,
          profile: @profile || 'general'
        )
      end

      # The German pointer lane (gesetzguide only; GERMAN_LANE_MODE). Reads
      # its mode when built, so one ask sees one mode.
      def german_article_search_svc
        @german_article_search_svc ||= LegalChatbot::GermanArticleSearch.new
      end

      # The controller decides the host (SiteBrand, never a parameter) and the
      # environment decides the mode; both must say yes. False everywhere but
      # on gesetzguide browser requests with the lane switched on.
      def german_lane?
        @german_lane == true && german_article_search_svc.active?
      end

      def jurisprudence_search_svc
        @jurisprudence_search_svc ||= LegalChatbot::JurisprudenceSearch.new(
          language: @language,
          embedding_service: embedding_svc
        )
      end

      def parliamentary_search_svc
        @parliamentary_search_svc ||= LegalChatbot::ParliamentarySearch.new(
          language: @language,
          embedding_service: embedding_svc
        )
      end

      def fisconet_search_svc
        @fisconet_search_svc ||= LegalChatbot::FisconetSearch.new(
          language: @language,
          embedding_service: embedding_svc
        )
      end

      def regional_search_svc
        @regional_search_svc ||= LegalChatbot::RegionalSearch.new(
          language: @language,
          embedding_service: embedding_svc
        )
      end
    end

    # Orchestrated multi-source search using service objects.
    # Called from ask_internal_multi as the clean path.
    #
    # Returns the same hash format as ask_internal_multi:
    #   { answer:, sources:, suggestions:, language:, response_time: }
    def orchestrated_multi_search(question, sources: [:legislation])
      start_time = Time.current
      phase_start = Time.current

      # Family benefits are community-specific. The regional corpus currently
      # has no German-speaking Community source, so fail closed before generic
      # semantic neighbours can substitute another Belgian regime.
      return no_answer_response(retrieval_status: 'unsupported_corpus') if unsupported_regional_corpus_question?(question)

      # Generate embeddings via service
      question_embedding = embedding_svc.generate(question)
      t_embed = ((Time.current - phase_start) * 1000).round
      phase_start = Time.current

      # HyDE (Hypothetical Document Embedding) - skip for smart tier to save ~3s
      # Only beneficial for premium tiers where answer quality matters more than speed
      hyde_embedding = if @reasoning_effort == 'low'
                         question_embedding # Skip HyDE - saves ~3s LLM call + embed
                       else
                         embedding_svc.generate_hyde(question) || question_embedding
                       end
      t_hyde = ((Time.current - phase_start) * 1000).round
      phase_start = Time.current

      # Parallel multi-source search via extracted service objects. The
      # degradation record is cleared HERE, not only in the fan-out: one
      # service instance can serve more than one ask, and four suites besides
      # the notice's own replace execute_parallel_searches by name at 14 call
      # sites (chatbot_answer_safety 1, legal_chatbot_incomplete_response 1,
      # legal_chatbot_quote_repair 2, legal_chatbot_quality_guardrails 10), so
      # a replaced fan-out must never inherit the previous ask's degraded
      # sources.
      @last_retrieval_degradation = nil
      all_results = execute_parallel_searches(sources, question, question_embedding, hyde_embedding)
      retrieval_searches = @last_retrieval_searches || ChatbotQualityEvidence.empty_retrieval_searches
      degraded_sources = @last_retrieval_degradation || {}
      t_search = ((Time.current - phase_start) * 1000).round
      phase_start = Time.current
      # Logged here rather than next to [Perf], so the record survives the
      # no-results return and a later provider failure.
      log_retrieval_degradation(sources, degraded_sources, retrieval_searches, t_search) if degraded_sources.any?

      leg_articles = all_results[:legislation] || []
      jur_cases = all_results[:jurisprudence] || []
      parl_docs = all_results[:parliamentary] || []
      tax_articles = all_results[:fisconet] || []
      regional_docs = all_results[:regional] || []

      # Apply quality filters to legislation. Hybrid FAISS/FTS retrieval now
      # happens inside LegislationSearch#search, so this remains safe even
      # when FAISS had no hits and FTS supplied the fallback results.
      leg_articles = apply_legislation_quality_filters(leg_articles, question)
      t_filter = ((Time.current - phase_start) * 1000).round
      phase_start = Time.current

      # Bound evidence volume separately from reasoning effort. Azure's high
      # reasoning mode otherwise received ~19K input tokens and exhausted a
      # 16K completion envelope entirely on hidden reasoning. The best-ranked
      # five statutes plus two cases and two preparatory works retain source
      # diversity while giving the model room to produce a visible answer.
      context_policy = reasoning_context_policy
      max_article_chars = context_policy.fetch(:max_article_chars)
      if context_policy[:bounded]
        leg_articles = leg_articles.take(context_policy.fetch(:legislation))
        jur_cases = jur_cases.take(context_policy.fetch(:jurisprudence))
        parl_docs = parl_docs.take(context_policy.fetch(:parliamentary))
        # Tax codes live ONLY in fisconet (BTW/WIB92 are empty in the main
        # laws DB); one snippet is rarely enough to answer a tax question
        # under the database-only prompt rule, so keep 3 even on the low tier.
        # NOT .take: FisconetSearch emits the regional variants of one article as an
        # indivisible group, and a bare take(3) splits it, which is exactly the partial
        # regional set that grouping exists to prevent. Same failure as the regional_docs
        # note below, reached by a different route.
        tax_articles = LegalChatbot::FisconetSearch.take_preserving_regional_groups(
          tax_articles, context_policy.fetch(:fisconet)
        )
        # Generic regionalised questions are deliberately stratified across
        # Flanders, Wallonia, and Brussels by RegionalSearch. Keeping only the
        # first result here silently undid that safety contract and made the
        # low tier answer from an arbitrary single region.
        regional_docs = regional_docs.take(context_policy.fetch(:regional))
      end

      # EU legislation is not part of the Belgian NUMAC corpus. Admit only
      # deterministic, topic-gated source records sealed by LegalFactProvider;
      # these flow through the same context, quote, link, and citation guards
      # as retrieved legislation.
      authoritative_docs = if sources.include?(:legislation)
                             reference_sheets_svc.select_authoritative_sources(question)
                           else
                             []
                           end

      # A processor question may only proceed when the sealed, locale-specific
      # EUR-Lex source set is complete. Never let unrelated Belgian retrieval
      # turn a missing official translation into an apparently grounded answer.
      return authoritative_source_unavailable_response if LegalFactProvider.gdpr_processor_question?(question) && authoritative_docs.empty?

      if leg_articles.empty? && jur_cases.empty? && parl_docs.empty? && tax_articles.empty? && regional_docs.empty? && authoritative_docs.empty?
        result = no_answer_response
        if @include_quality_evidence
          result[:quality_evidence] = ChatbotQualityEvidence.skipped(
            retrieval_searches: retrieval_searches
          )
        end
        # "I found no provision" after a search that did not complete is the
        # 2026-09-20 answer in its purest form; it must not stand alone. The
        # notice LEADS on this path instead of trailing: no_governing_rule_message
        # (prompts.rb) opens with "in de Belgische geconsolideerde wetgeving die
        # ik heb doorzocht", which asserts a completed search, so the qualifier
        # has to be read before the claim it qualifies. Rewording that message
        # is an owner decision on a file outside this change. Nothing else is
        # at risk here: no_answer_response returns sources: [], so this path
        # stores no NUMACs.
        return apply_retrieval_notice!(result, degraded_sources, lead: true)
      end

      # Build combined context via service
      context = build_combined_context_from_db(
        leg_articles,
        jur_cases,
        parl_docs,
        tax_articles,
        regional_docs,
        max_article_chars: max_article_chars,
        authoritative_docs: authoritative_docs,
        question: question
      )
      context = ensure_utf8(context)
      t_context = ((Time.current - phase_start) * 1000).round

      # Release DB connection before LLM call (15-25s)
      ActiveRecord::Base.connection_pool.release_connection

      phase_start = Time.current
      # Query LLM via service
      publish_phase(:generating)
      answer = llm_svc.query(question, context, source_type: :all, conversation_messages: conversation_messages)
      answer = ensure_utf8(answer)
      ChatbotAnswerSafety.validate_visible_answer!(answer)
      t_llm = ((Time.current - phase_start) * 1000).round

      suggestions = generate_follow_up_suggestions(question)
      total_ms = ((Time.current - start_time) * 1000).round

      # Performance instrumentation - grep for [Perf] to diagnose latency
      Rails.logger.info("[Perf] Pipeline: embed=#{t_embed}ms hyde=#{t_hyde}ms search=#{t_search}ms filter=#{t_filter}ms context=#{t_context}ms llm=#{t_llm}ms total=#{total_ms}ms | sources=#{sources.join(',')} effort=#{@reasoning_effort} model=#{@model_override || 'default'} results=L#{leg_articles.size}/J#{jur_cases.size}/P#{parl_docs.size}/T#{tax_articles.size}/R#{regional_docs.size}")

      # Per-answer guard telemetry, reset explicitly: one service instance can
      # serve more than one ask (ask_with_sources, retries).
      @citation_guard_outcome = nil
      @citation_guard_rejection = nil
      @citation_guard_retries = 0
      statutory_sources = leg_articles + tax_articles + regional_docs + authoritative_docs
      guard_sources = {
        statutory_sources: statutory_sources,
        leg_articles: leg_articles, tax_articles: tax_articles,
        jur_cases: jur_cases, parl_docs: parl_docs,
        regional_docs: regional_docs, authoritative_docs: authoritative_docs
      }
      # QUOTE-ATTRIBUTION REPAIR, before the guards run at all. A quote
      # attributed to an article of a retrieved law that retrieval did not
      # return cannot verify, so QuoteGuard replaces it with "geen exact
      # citaat beschikbaar" - visible twice in one owner-reported answer
      # (31 July, "Moet contract schriftelijk zijn?"). Deepening the evidence
      # first costs one indexed lookup and no provider call, and cannot rescue
      # a false quote: the words must still occur verbatim in the fetched text.
      quote_repairs = repair_quote_sources(answer, leg_articles)
      if quote_repairs.any?
        leg_articles += quote_repairs
        statutory_sources = leg_articles + tax_articles + regional_docs + authoritative_docs
        guard_sources = guard_sources.merge(
          statutory_sources: statutory_sources, leg_articles: leg_articles
        )
        context = ensure_utf8(
          build_combined_context_from_db(
            leg_articles, jur_cases, parl_docs, tax_articles, regional_docs,
            max_article_chars: max_article_chars, authoritative_docs: authoritative_docs,
            question: question
          )
        )
        Rails.logger.info("[QuoteRepair] added #{quote_repairs.length} quote-attributed article(s)")
      end

      publish_phase(:verifying)
      clean_answer = apply_answer_guard_chain(answer, question, guard_sources)

      # Corrective regeneration, up to CITATION_GUARD_MAX_RETRIES attempts.
      # Most CitationGuard blocks are the model citing an article outside (or
      # unlinkable to) the retrieved set; without a retry every such block
      # degrades the answer to a source-list fallback (~29% of asks on
      # 2026-07-28). A retry that names the rejected references converts most.
      #
      # The second attempt is justified by measurement, not optimism: on
      # 2026-07-30 all 53 answers the guard had withheld in the stratified-275
      # spot check were re-asked, and 27 (51%) produced a verified analysis on
      # a plain re-ask of the same release and corpus. Half of these rejections
      # are stochastic, so one extra attempt recovers roughly half of what one
      # attempt leaves behind. Still strictly bounded: the guard remains the
      # authority, never a target to iterate against, and each attempt costs a
      # provider call, so this stays a small constant.
      # CITATION REPAIR, before any re-prompting. Measured on the 2026-07-29
      # sample: of 89 rejected citations, 77 (87%) were articles that exist in
      # a law the same search had already returned, and 24 of the 26 withheld
      # answers had at least one. Re-prompting cannot fix that - the model
      # named a real article the evidence simply lacked. So look the cited
      # articles up in the retrieved laws, add what exists to the evidence,
      # and regenerate against the deepened context.
      #
      # This can only ever deepen evidence within laws the search justified;
      # a citation pointing outside them resolves to nothing and stays
      # rejected. The regenerated answer goes through the identical guard
      # chain, so nothing is trusted that was not verified.
      unless citation_guard_passed?
        repaired = repair_cited_articles(@last_citation_guard_result, leg_articles)
        if repaired.any?
          leg_articles += repaired
          statutory_sources = leg_articles + tax_articles + regional_docs + authoritative_docs
          guard_sources = guard_sources.merge(
            statutory_sources: statutory_sources, leg_articles: leg_articles
          )
          repaired_context = ensure_utf8(
            build_combined_context_from_db(
              leg_articles, jur_cases, parl_docs, tax_articles, regional_docs,
              max_article_chars: max_article_chars, authoritative_docs: authoritative_docs,
              question: question
            )
          )
          begin
            publish_phase(:refining, attempt: 1)
            repaired_answer = llm_svc.query(
              question, repaired_context,
              source_type: :all,
              conversation_messages: conversation_messages
            )
            repaired_answer = ensure_utf8(repaired_answer)
            ChatbotAnswerSafety.validate_visible_answer!(repaired_answer)
            context = repaired_context
            clean_answer = apply_answer_guard_chain(repaired_answer, question, guard_sources)
            Rails.logger.info(
              "[CitationRepair] regenerated with #{repaired.length} added article(s); " \
              "verified=#{citation_guard_passed?}"
            )
          rescue StandardError => e
            Rails.logger.warn("[CitationRepair] regeneration skipped: #{e.class}")
          end
        end
      end

      unless citation_guard_passed?
        first_clean_answer = clean_answer
        first_citation_result = @last_citation_guard_result
        first_quote_result = @last_quote_guard_result
        attempts = 0
        while attempts < CITATION_GUARD_MAX_RETRIES && !citation_guard_passed?
          corrective = citation_guard_corrective_feedback(@last_citation_guard_result)
          break if corrective.blank?

          attempts += 1
          publish_phase(:refining, attempt: attempts)
          begin
            retry_answer = llm_svc.query(
              question, context,
              source_type: :all,
              conversation_messages: conversation_messages,
              corrective_feedback: corrective
            )
            retry_answer = ensure_utf8(retry_answer)
            ChatbotAnswerSafety.validate_visible_answer!(retry_answer)
            clean_answer = apply_answer_guard_chain(retry_answer, question, guard_sources)
            if citation_guard_passed?
              Rails.logger.info(
                "[CitationGuard] corrective retry #{attempts} produced a verified answer"
              )
            end
          rescue StandardError => e
            Rails.logger.warn("[CitationGuard] corrective retry #{attempts} failed: #{e.class}")
            break
          end
        end
        @citation_guard_retries = attempts
        unless citation_guard_passed?
          # Report the original generation's verdict, not the last retry's: the
          # fallback path and analytics describe the first attempt.
          clean_answer = first_clean_answer
          @last_citation_guard_result = first_citation_result
          @last_quote_guard_result = first_quote_result
        end
      end

      unless citation_guard_passed?
        # Preserve WHY the analysis was rejected before the fallback overwrites
        # it. The source-list fallback contains only verified links, so it
        # passes the guard, and re-validating it replaced the rejecting result
        # with a passing one. That made `citations_verified` read true for an
        # answer whose analysis was withheld, and destroyed the only record of
        # the offending references, the exact data needed to decide whether a
        # rejection was retryable (unsupported prose refs) or structural (a
        # required regime that retrieval never returned).
        @citation_guard_rejection = @last_citation_guard_result
        # A SALVAGE PASS WAS TRIED AND SHELVED, 2026-08-04. Delivering the
        # rejected analysis with unverifiable references neutralized looks
        # obviously right - it was the largest withheld-POOR cluster (31 of
        # 58, docs/ops/withheld-answers-2026-08-04.md) - but three independent
        # adversarial review rounds each confirmed blockers where the rewrite
        # MISSTATED THE EVIDENCE to the reader: claiming a provision was
        # absent when the guard had only failed to link it (while the source
        # card deep-linked that same article), and shipping live tail numbers
        # from range and paragraph citations that the guard's own scan cannot
        # see. The full history and the shelved implementation are on branch
        # salvage-pass-shelved-20260804. Do not resurrect it without a
        # mechanism that cannot make a claim the guard has not established.
        verified_fallback = high_confidence_topic_fallback_answer(question, statutory_sources)
        verified_fallback = citation_guard_source_list_fallback_answer(statutory_sources) if verified_fallback.blank?
        if verified_fallback.present?
          verified_fallback = validate_answer_links(
            verified_fallback, leg_articles, tax_articles, jur_cases, parl_docs, regional_docs, authoritative_docs
          )
          clean_answer = validate_unlinked_article_citations(verified_fallback, statutory_sources)
          @citation_guard_outcome = 'verified_sources_fallback'
        else
          @citation_guard_outcome = 'refusal'
        end

        # One uniform, greppable record per degraded delivery. Nothing else
        # persists the outcome (ChatbotAnalytic has no column for it), so
        # without this the fallback/refusal mix is unmeasurable in
        # production (Opus review, 2026-08-04). Counts and the outcome name
        # only - guard payloads are barred from the logs by contract.
        Rails.logger.info(
          "[CitationGuardOutcome] outcome=#{@citation_guard_outcome} " \
          "retries=#{@citation_guard_retries.to_i} " \
          "rejected_count=#{@citation_guard_rejection&.fetch(:rejected, 0).to_i}"
        )
      end

      # TODO: If users complain about irrelevant sources in the UI list (not the answer),
      # consider adding a cheap Mistral Small pre-filter here to semantically filter
      # jur_cases/parl_docs before formatting. Cost: ~€0.001/query, +1.5-3s latency.
      # The LLM prompt already silently ignores irrelevant sources in the answer text,
      # but the UI source list (format_all) still shows everything retrieved.
      # See: implementation_plan.md "Option 2: Cheap LLM Pre-Filter"
      result = {
        answer: clean_answer,
        # Fisconet and regional results have their own shapes (no numac/law_title),
        # so they must go through their services' own formatters; routing them
        # through format_legislation silently dropped every entry.
        sources: source_formatter_svc.format_all(
          legislation: leg_articles,
          jurisprudence: jur_cases,
          parliamentary: parl_docs
        ) + fisconet_search_svc.format_sources(tax_articles) +
                 regional_search_svc.format_sources(regional_docs) +
                 source_formatter_svc.format_authoritative(authoritative_docs),
        suggestions: suggestions,
        language: @language,
        # Server-side QuoteGuard has checked every blockquote that remains in
        # `answer`. The benchmark can trust this compact attestation without
        # exposing full statutory source text in the public source cards.
        quotes_verified: @last_quote_guard_result&.fetch(:verified, false) == true,
        quote_guard: @last_quote_guard_result,
        citations_verified: @last_citation_guard_result&.fetch(:passed, false) == true,
        citation_guard: @last_citation_guard_result,
        # Present only when the generated analysis was withheld. `analysis`
        # says a real analysis was delivered; anything else means the user got
        # verified sources or a refusal instead, and `citation_guard_rejection`
        # carries the original verdict that caused it.
        citation_guard_outcome: @citation_guard_outcome || 'analysis',
        citation_guard_rejection: @citation_guard_rejection,
        citation_guard_retries: @citation_guard_retries || 0,
        response_time: (Time.current - start_time).round(2)
      }
      # Before the guard-failure marker below, which copies :answer into
      # :error: a refusal must keep showing exactly the text it refunds.
      apply_retrieval_notice!(result, degraded_sources)
      # CitationGuard rejection means no verified legal answer was delivered.
      # Mark it as an error so every controller path refunds/skips the charge;
      # the localized message remains the user-facing explanation.
      mark_citation_guard_failure!(result)
      if @include_quality_evidence
        # NO degradation field here, and that is a measurement gap, not an
        # oversight. For the 2026-09-20 shape this row reads perfectly healthy:
        # retrieval_status 'results', generation_status 'generated',
        # source_counts[:legislation] = 3 and retrieval_searches[:legislation]
        # 'completed' (the worker really did complete; only its semantic leg
        # failed), and ChatbotQualityEvidence.validation_errors passes it.
        # ChatbotAnalytic has no column for it either (api/chatbot_analytics.rb
        # writes a fixed list) and scripts/capture_chatbot_quality_run.rb keeps
        # only answer/sources/quality_evidence/quality_provenance, so a degraded
        # ask is measurable ONLY by grepping [RetrievalDegraded]. The key set
        # below is validated exactly, so adding :retrieval_degraded means
        # changing ChatbotQualityEvidence and its validator together: do it at
        # the next evidence schema bump rather than alongside the notice.
        evidence_context = llm_svc.last_evidence_context.to_s
        result[:quality_evidence] = ChatbotQualityEvidence.generated(
          context: evidence_context,
          provider_model: llm_svc.last_provider_model,
          source_counts: {
            legislation: leg_articles.length + authoritative_docs.length,
            jurisprudence: jur_cases.length,
            parliamentary: parl_docs.length,
            fisconet: tax_articles.length,
            regional: regional_docs.length
          },
          retrieval_searches: retrieval_searches
        )
      end
      result
    rescue LegalChatbot::LlmClient::IncompleteProviderResponse
      # A provider can return HTTP 200 while supplying no visible text or while
      # exhausting its output budget mid-answer. Treat that as a non-billable
      # terminal error; a polite fallback must never be mistaken for a paid
      # legal answer.
      Rails.logger.error(
        "[AnswerSafety] Blocked incomplete provider response " \
        "(model=#{@model_override || 'default'}, language=#{@language})"
      )
      incomplete_message = LegalChatbot::LlmClient.incomplete_response_message(@language)
      {
        answer: incomplete_message,
        sources: [],
        suggestions: [],
        language: @language,
        quotes_verified: false,
        citations_verified: false,
        response_time: (Time.current - start_time).round(2),
        error: incomplete_message,
        error_code: LegalChatbot::LlmClient::INCOMPLETE_RESPONSE_ERROR_CODE
      }
    rescue ChatbotAnswerSafety::UnsafeProviderReasoningPayload
      # Never attempt to salvage a stringified typed response: visible text and
      # private reasoning can be interleaved. Returning an error makes the
      # controller refund the reservation, while the localized replacement is
      # safe for every response and history path.
      Rails.logger.error(
        "[AnswerSafety] Blocked provider reasoning payload " \
        "(model=#{@model_override || 'default'}, language=#{@language})"
      )
      blocked_message = ChatbotAnswerSafety.blocked_message(@language)
      {
        answer: blocked_message,
        sources: [],
        suggestions: [],
        language: @language,
        quotes_verified: false,
        citations_verified: false,
        response_time: (Time.current - start_time).round(2),
        error: blocked_message,
        error_code: ChatbotAnswerSafety::ERROR_CODE
      }
    rescue LegalChatbot::ModelsConfig::BudgetLimitExceeded
      # The controller is the single settlement boundary for an answer: it
      # maps an authoritative post-advisory rejection to 429/SSE and refunds
      # the already-reserved user credits exactly once. Converting this into a
      # generic result would hide the cap behind HTTP 200 and bypass that path.
      raise
    rescue StandardError => e
      # Provider and retrieval exceptions can contain echoed request material.
      # Keep operational class/backtrace data, never their free-form message.
      error_msg = "Orchestrator error: #{e.class}\n#{e.backtrace&.first(10)&.join("\n")}"
      Rails.logger.error(error_msg)
      $stderr.puts("[ORCHESTRATOR ERROR] #{error_msg}")
      { error: 'An error occurred' }
    end

    # LinkGuard: validate every internal link the model wrote. The prompt
    # instructs the model to only copy LINK values from the context, but cheap
    # tiers sometimes slugify a law title into /laws/btw-wetboek, a route
    # that does not exist (law pages are keyed by NUMAC or FISCONET_<id>).
    # Policy per citation link:
    #   - target belongs to a source retrieved this turn → keep
    #   - lowercase/miscased fisconet id                 → normalize to FISCONET_
    #   - slug matching a retrieved tax code's title     → rewrite to its page
    #   - anything else                                  → degrade to plain text
    # Runs BEFORE auto_linkify so degraded references can be re-linked from
    # retrieved sources with canonical URLs.
    # Deterministic quote guard. Prompt instructions reduce fabrication but do
    # not make a lower-cost model trustworthy: every Markdown blockquote must
    # occur verbatim in one of the source texts supplied to that same answer.
    # A list marker before the ">" ("- > ...", "1. > ...") still opens a
    # quotation: German answers v6 found four statutory quotations set as list
    # items that the guard and the translation's protection did not see.
    MARKDOWN_BLOCKQUOTE_PATTERN = /(?:^[ ]{0,3}(?:(?:[-*+]|\d{1,2}[.)])[ ]+)?>[^\n]*(?:\n|\z))+/.freeze
    MARKDOWN_LINK_PATTERN = /!?\[[^\]\n]+\]\([^)\n]+\)/.freeze
    ARTICLE_SPACE_SOURCE = '[[:space:]\u00A0\u2007\u202F]'.freeze
    ARTICLE_PREFIX_SOURCE = '(?i:(?:Art(?:t|s)?\.?|Artikel(?:en|s)?|Article(?:s)?))'.freeze
    # The LINKIFIER may not share the prefix above, because the two have
    # OPPOSITE SAFETY POLARITIES: over-matching in the gate causes a rejection
    # (fail-closed), over-matching in the linkifier MINTS a citation
    # (fail-open). The gate's plural alternatives let a Dutch/French noun's own
    # ending be consumed so the pattern lands on a following number - "uw arts.
    # 3 werkdagen" and "de artikelen 14 dagen na levering" (the canonical
    # withdrawal-right sentence, where artikelen means goods) both became
    # fabricated citations (Opus review, 2026-08-04). Measured: this set
    # matches every real citation form including "Artt." and NBSP variants
    # while minting nothing from that prose.
    # The dot belongs ONLY to the abbreviation. "Art." / "Artt." are
    # abbreviations whose dot is part of the token; "artikel" / "article" are
    # ordinary words whose following dot ends a SENTENCE, so allowing it there
    # turns "Dat staat in dat artikel. 3 werkdagen later" into a fabricated
    # citation. That shape mints in the pre-series baseline too (measured), so
    # this placement fixes a live defect rather than merely avoiding a new one.
    LINKIFY_ARTICLE_PREFIX_SOURCE = '(?:Artikel|Article|Artt?\.?)'.freeze
    ARTICLE_NUMBER_TOKEN_SOURCE =
      '(?:[0-9]+[[:alpha:]]*|[IVXLCDM]+\.[0-9]+[[:alpha:]]*)(?:(?:[[:space:]\u00A0\u2007\u202F]*[\/:\-][[:space:]\u00A0\u2007\u202F]*[0-9]+[[:alpha:]]*)|(?:[[:space:]\u00A0\u2007\u202F]*\.[[:space:]\u00A0\u2007\u202F]*[0-9]+[[:alpha:]]*))*'.freeze
    ARTICLE_NUMBER_TOKEN_PATTERN = Regexp.new(ARTICLE_NUMBER_TOKEN_SOURCE).freeze
    SINGLE_ARTICLE_CITATION_PATTERN = Regexp.new(
      "\\b#{ARTICLE_PREFIX_SOURCE}#{ARTICLE_SPACE_SOURCE}*(?:(?i:(?:nrs?|nos?)\\.)|n[°º])?#{ARTICLE_SPACE_SOURCE}*(?<number>#{ARTICLE_NUMBER_TOKEN_SOURCE})"
    ).freeze
    ARTICLE_LIST_SEPARATOR_SOURCE =
      "(?:#{ARTICLE_SPACE_SOURCE}*(?:,|;|[&+])#{ARTICLE_SPACE_SOURCE}*(?:(?i:en|et|and|und|of|ou)#{ARTICLE_SPACE_SOURCE}+)?|#{ARTICLE_SPACE_SOURCE}+(?i:en|et|and|und|of|ou)#{ARTICLE_SPACE_SOURCE}+)".freeze
    ARTICLE_CITATION_SEQUENCE_PATTERN = Regexp.new(
      "\\b#{ARTICLE_PREFIX_SOURCE}#{ARTICLE_SPACE_SOURCE}*(?:(?i:(?:nrs?|nos?)\\.)|n[°º])?#{ARTICLE_SPACE_SOURCE}*(?<numbers>#{ARTICLE_NUMBER_TOKEN_SOURCE}(?:#{ARTICLE_LIST_SEPARATOR_SOURCE}(?:#{ARTICLE_PREFIX_SOURCE}#{ARTICLE_SPACE_SOURCE}*)?#{ARTICLE_NUMBER_TOKEN_SOURCE})*)"
    ).freeze
    PLAIN_QUOTE_ARTICLE_ATTRIBUTION_PATTERN =
      /(?:\s+[—–]\s+|\s+-\s+)\[?Art(?:ikel|icle)?\.?\s*([[:alnum:]]+(?:\s*[\/.:-]\s*[[:alnum:]]+)*)(?=[\s§,;\]]|\.?(?:\s|\z))/i.freeze
    PLAIN_QUOTE_ARTICLE_ATTRIBUTION_SUFFIX_PATTERN =
      /(?:\s+[—–]\s+|\s+-\s+)\[?Art(?:ikel|icle)?\.?\s*[[:alnum:]]+(?:\s*[\/.:-]\s*[[:alnum:]]+)*(?=[\s§,;\]]|\.?(?:\s|\z)).*\z/i.freeze

    DRUG_CITATION_ARTICLE_PRIORITY = {
      '1921022450' => %w[2bis 2ter],
      '2017031231' => %w[6 61]
    }.freeze

    def reasoning_context_policy
      provider = LegalChatbotService::AVAILABLE_MODELS.dig(@model_override, :provider)
      high_azure_reasoning = @reasoning_effort == 'high' && provider == :openai

      if @reasoning_effort == 'low'
        {
          bounded: true,
          max_article_chars: 2500,
          legislation: 5,
          jurisprudence: 2,
          parliamentary: 2,
          fisconet: 3,
          regional: 3
        }
      elsif high_azure_reasoning
        if @model_override == 'gpt-5'
          # The older GPT-5 deployment needs materially more wall time at high
          # effort than the 5.6 family. Keep one result from each non-statutory
          # source and the four best statutes so it can finish inside the
          # browser/proxy deadline without collapsing to legislation-only RAG.
          {
            bounded: true,
            max_article_chars: 2500,
            legislation: 4,
            jurisprudence: 1,
            parliamentary: 1,
            fisconet: 3,
            regional: 3
          }
        else
          {
            bounded: true,
            max_article_chars: 3000,
            legislation: 5,
            jurisprudence: 2,
            parliamentary: 2,
            fisconet: 3,
            regional: 3
          }
        end
      else
        { bounded: false, max_article_chars: 4000 }
      end
    end

    # Bind a quote to the source named in its attribution. Previously a quote
    # copied from retrieved Art. B survived when it was labelled and linked as
    # retrieved Art. A, because QuoteGuard searched every source while
    # LinkGuard independently accepted both article links. An explicit
    # attribution now narrows verification to that exact retrieved source.
    #
    # nil => no source attribution was present (fall back to all sources)
    # []  => an attribution was present but did not identify a retrieved source
    # The full post-generation guard chain, applied identically to the first
    # generation and to the corrective retry. Order matters: LinkGuard FIRST
    # strips/repairs fabricated links (e.g. slugified /laws/btw-wetboek), THEN
    # auto_linkify re-links degraded references from retrieved sources, the
    # deterministic citation appenders run on linkified text, and CitationGuard
    # judges the final payload. Auto-linkification is a response mutation too,
    # so LinkGuard runs again before the citation verdict.
    def apply_answer_guard_chain(answer, question, guard_sources)
      statutory_sources = guard_sources.fetch(:statutory_sources)
      link_guard_args = [
        guard_sources.fetch(:leg_articles), guard_sources.fetch(:tax_articles),
        guard_sources.fetch(:jur_cases), guard_sources.fetch(:parl_docs),
        guard_sources.fetch(:regional_docs), guard_sources.fetch(:authoritative_docs)
      ]
      clean_answer = sanitize_answer(answer)
      clean_answer = validate_answer_quotes(
        clean_answer,
        statutory_sources + guard_sources.fetch(:jur_cases) + guard_sources.fetch(:parl_docs)
      )
      clean_answer = validate_answer_links(clean_answer, *link_guard_args)
      clean_answer = auto_linkify_articles(clean_answer, statutory_sources)
      # Drug-offence answers depend on two complementary regimes; processor
      # questions require both GDPR Art. 4(8) and Art. 28; a few
      # diagnosis-backed high-risk topics get a canonical citation appended.
      # Each appender only uses sources retrieved this turn, and CitationGuard
      # fails closed when a required regime was not retrieved at all.
      clean_answer = ensure_required_drug_regime_citations(clean_answer, question, statutory_sources)
      clean_answer = ensure_required_gdpr_processor_citations(clean_answer, question, statutory_sources)
      clean_answer = ensure_high_confidence_topic_citations(clean_answer, question, statutory_sources)
      clean_answer = validate_answer_links(clean_answer, *link_guard_args)
      validate_unlinked_article_citations(clean_answer, statutory_sources)
    end

    # Bounded corrective regenerations after a CitationGuard rejection. Two,
    # because measurement (2026-07-30) put the per-attempt recovery rate near
    # 50%: attempt one converts most rejections, attempt two roughly half of
    # the remainder, and each costs a provider call.
    CITATION_GUARD_MAX_RETRIES = 2

    # The repair calculators live in LegalChatbot::CitationRepair (FBL-061);
    # this alias keeps the measured-budget constant reachable at its
    # long-standing name, which tests and docs reference. A later span cut
    # once swallowed this alias into AnswerGuards - it belongs HERE.
    CITATION_REPAIR_LIMIT = CitationRepair::CITATION_REPAIR_LIMIT

    # ------------------------------------------------------------------
    # RETRIEVAL NOTICE
    # ------------------------------------------------------------------
    #
    # 2026-09-20, 05:37 UTC: the first question in about 14 hours, 80 s after
    # a deploy, met three cold mmap'd FAISS indexes. [Perf] read
    # search=30002ms total=32685ms results=L3/J0/P0/T0/R0: jurisprudence and
    # parliamentary ran into the shared 30 s deadline, the legislation
    # semantic leg gave up after its 10 s read and keywords filled in. The
    # model said, correctly, that its three "kleding" articles did not cover
    # the question, and nothing told the user that the search behind that
    # answer had been incomplete. It recurs (faiss-large answered too late on
    # 12 of the 21 days before it), so the answer now says so itself.
    #
    # Inserted into the finished text, deterministically. Asking the model to
    # mention it would need a PROMPT_VERSION bump, is unreliable on the small
    # default tier and invites "my sources are incomplete, so from general
    # knowledge", which breaks the database-only rule. Plain text also reaches
    # every surface (widget, full page, legacy HTML page, exports, service
    # clients) without a Vite build.
    #
    # Hard signals only (SearchFanOut fills @last_retrieval_degradation): a
    # low similarity, few hits or an empty result never counts, so a healthy
    # search cannot fire it. It also cannot fire for a silently failed
    # :fisconet search - see the COVERAGE GAP note in search_fan_out.rb.
    #
    # It names no cause: the fan-out establishes only THAT a source was not
    # searched through, never why. The first draft said "door een tijdelijke
    # vertraging", which is wrong for 'error' (also a refused connection to a
    # dead unit and a missing chamber.sqlite3, see parliamentary_search.rb and
    # regional_search.rb) and for 'saturated' (the worker cap was full).
    #
    # It invites the user to ask again in a moment only for the two reasons a
    # short wait cures, RETRIEVAL_RETRY_REASONS below: a source that ran into
    # the shared deadline and a semantic leg that gave up, which is what a
    # cold index warming up looks like (owner decision, 2026-09-26). Not for
    # 'error', which waiting does not cure, nor for 'saturated', where a
    # prompted re-ask would pile onto the pool that was already starved. The
    # re-ask is charged in full; it is no longer retrieval-poisoned, because
    # api/conversation_persistence.rb stores no context NUMACs for a degraded
    # ask (see apply_retrieval_notice! below).
    #
    # The degraded answer itself costs no credit (owner default, 2026-09-27,
    # to-do 6.7): api/chatbot_controller.rb releases the reservation of any
    # result that carries :retrieval_degraded, whatever the reason, and adds
    # RETRIEVAL_FREE_ANSWER_NOTES to the notice through with_free_answer_note.
    # Billing stays in the controller, which alone knows whether anything was
    # reserved; this module only owns the copy.
    RETRIEVAL_RETRY_REASONS = %w[timeout semantic_unavailable].freeze

    RETRIEVAL_NOTICE_SOURCE_LABELS = {
      'nl' => {
        legislation: 'de wetgeving', jurisprudence: 'de rechtspraak',
        parliamentary: 'de parlementaire voorbereidingen',
        fisconet: 'de fiscale wetgeving', regional: 'de regionale wetgeving'
      },
      'fr' => {
        legislation: 'la législation', jurisprudence: 'la jurisprudence',
        parliamentary: 'les travaux préparatoires',
        fisconet: 'la législation fiscale', regional: 'la législation régionale'
      },
      'en' => {
        legislation: 'legislation', jurisprudence: 'case law',
        parliamentary: 'preparatory works',
        fisconet: 'tax legislation', regional: 'regional legislation'
      },
      'de' => {
        legislation: 'die Gesetzgebung', jurisprudence: 'die Rechtsprechung',
        parliamentary: 'die parlamentarischen Vorarbeiten',
        fisconet: 'die Steuergesetzgebung', regional: 'die regionale Gesetzgebung'
      }
    }.freeze

    # The lines a model appends after its analysis: the follow-up hint (light
    # bulb), the privacy tip (warning sign) and the disclaimer, plus the blank
    # and rule lines between them. They are MODEL-written (build_system_prompt
    # asks for "Dit is geen officieel juridisch advies." and the three
    # translations), so the wording is not guaranteed and the disclaimer is
    # recognised by shape rather than by one fixed sentence.
    #
    # The shape is a DEMONSTRATIVE SUBJECT plus the negation: the disclaimer
    # denies that THIS ANSWER is legal advice. Matching the negation alone was
    # too permissive - the same family as the two ART_NUM_RE bugs, a pattern
    # careless about what surrounds the token. "U hebt geen recht op kosteloos
    # juridisch advies." and "You are not entitled to free legal advice." both
    # matched, and the trailing-run walk-back below then placed the notice
    # above a real closing sentence. The failure in the other direction costs
    # nothing: an unrecognised disclaimer only means the notice is appended
    # below it instead of above it.
    RETRIEVAL_NOTICE_FOOTER_LINE = Regexp.union(
      /\A[\s>*_-]*\z/,
      /\A[\s>*_]*(?:\u{1F4A1}|\u{26A0})/,
      /\A[\s>*_]*(?:dit|deze|dat)\b[^\n]{0,30}\bgeen\b[^\n]{0,40}\bjuridisch advies\b/i,
      /\A[\s>*_]*(?:ceci|cela|cette|le présent|la présente)\b[^\n]{0,30}\bpas\b[^\n]{0,40}\b(?:avis|conseil) juridique\b/i,
      /\A[\s>*_]*(?:this|that|the above|it)\b[^\n]{0,30}\bnot\b[^\n]{0,40}\blegal advice\b/i,
      /\A[\s>*_]*(?:dies|das|diese[rs]?)\b[^\n]{0,30}\bkein(?:e|en)?\b[^\n]{0,40}\b(?:Rechtsberatung|Rechtsrat|Rechtsauskunft)\b/i
    ).freeze

    # The bolded opener of each localized notice, used to REMOVE one. The
    # notice lives in result[:answer], which api/conversation_persistence.rb
    # persists verbatim and which comes back to the model as one of the last
    # six messages, so the model can echo it into a LATER answer. That copy is
    # plain prose with no citation, so every guard passes it: a warning firing
    # on healthy behaviour, with no [RetrievalDegraded] line to contradict it.
    RETRIEVAL_NOTICE_LEADS = [
      'Let op: de zoekopdracht was onvolledig.',
      'Attention : la recherche était incomplète.',
      'Please note: the search was incomplete.',
      'Hinweis: Die Suche war unvollständig.'
    ].freeze

    RETRIEVAL_NOTICE_PARAGRAPH = /\A[\s>*_]*#{Regexp.union(RETRIEVAL_NOTICE_LEADS)}/

    # One greppable record per degraded ask. Source names, reasons and
    # numbers only: the question is personal data, and an exception message
    # can echo it.
    def log_retrieval_degradation(sources, degraded, retrieval_searches, search_ms)
      durations = retrieval_searches.filter_map do |source, record|
        next if %w[not_requested not_applicable].include?(record[:status])

        "#{source}:#{record[:duration_ms]}"
      end
      Rails.logger.warn(
        "[RetrievalDegraded] sources=#{sources.join(',')} " \
        "degraded=#{degraded.map { |source, reason| "#{source}:#{reason}" }.join(',')} " \
        "durations_ms=#{durations.join(',')} search=#{search_ms}ms"
      )
    end

    # Source NAMES go to the client (the result hash is serialized as is);
    # the reasons stay in the log. No :error key: the answer is delivered,
    # and :error would turn it into an error bubble without source cards.
    #
    # result[:retrieval_degraded] is also what keeps the invited re-ask clean:
    # api/conversation_persistence.rb (#context_numacs_for) stores no context
    # NUMACs for a result that carries it. Otherwise the degraded ask's
    # sources would lead the conversation's 10-slot context_numacs list, and
    # the next ask would INJECT them and multiply their score by
    # CONTEXT_LAW_BOOST = 2.5 (legislation_search.rb). On 2026-09-20 that
    # would have force-fed the rest-home-hygiene, nickel-limit and
    # identity-card articles into the re-ask, at full charge.
    def apply_retrieval_notice!(result, degraded, lead: false)
      # Strip first and unconditionally, so exactly one notice survives and it
      # is this ask's: an echoed copy from the replayed history would otherwise
      # ride along on a healthy answer, or name the previous ask's sources.
      result[:answer] = without_retrieval_notice(result[:answer])
      return result if degraded.blank?

      retry_later = degraded.values.any? { |reason| RETRIEVAL_RETRY_REASONS.include?(reason.to_s) }
      result[:answer] = with_retrieval_notice(result[:answer], degraded.keys, lead: lead, retry_later: retry_later)
      result[:retrieval_degraded] = degraded.keys.map(&:to_s)
      result
    end

    # Removes an echoed notice paragraph. Returns the SAME string when there is
    # nothing to remove, so a healthy answer stays byte-identical, and keeps
    # the text untouched when the notice is all there is, rather than
    # delivering an empty answer.
    def without_retrieval_notice(answer)
      return answer unless answer.is_a?(String)

      paragraphs = answer.split(/\n{2,}/)
      kept = paragraphs.grep_v(RETRIEVAL_NOTICE_PARAGRAPH)
      return answer if kept.length == paragraphs.length || kept.empty?

      kept.join("\n\n").strip
    end

    # Above the generic tips, so it reads as part of the answer and not as one
    # more boilerplate line under them. Only the TRAILING run of footer lines
    # is examined, so nothing in the body can match; with no footers (every
    # code-built message) this is a plain append. `lead:` puts it on top
    # instead, for a message that already claims to have searched everything.
    def with_retrieval_notice(answer, sources, lead: false, retry_later: false)
      notice = retrieval_notice_text(sources, retry_later: retry_later)
      text = answer.to_s
      return text if text.include?(notice)
      return [notice, text].reject(&:blank?).join("\n\n") if lead

      lines = text.split("\n", -1)
      body_length = lines.length
      body_length -= 1 while body_length.positive? && lines[body_length - 1].match?(RETRIEVAL_NOTICE_FOOTER_LINE)

      [
        lines.take(body_length).join("\n").rstrip,
        notice,
        lines.drop(body_length).join("\n").strip
      ].reject(&:blank?).join("\n\n")
    end

    # The closing sentence for RETRIEVAL_RETRY_REASONS, in the notice's own
    # paragraph so that stripping an echoed notice also strips it.
    RETRIEVAL_RETRY_INVITATIONS = {
      'nl' => 'U kunt uw vraag over een ogenblik opnieuw stellen.',
      'fr' => 'Vous pouvez reposer votre question dans un instant.',
      'en' => 'You can ask your question again in a moment.',
      'de' => 'Sie können Ihre Frage in einem Moment erneut stellen.'
    }.freeze

    # Added by the controller once it has released the credit reservation of
    # a degraded answer (to-do 6.7). Same paragraph as the notice, for the
    # same reason as the invitation: history replay strips the paragraph, so
    # the model can never echo "this answer was free" into a charged one.
    # No model or provider name, no cause.
    RETRIEVAL_FREE_ANSWER_NOTES = {
      'nl' => 'Dit antwoord kostte u geen credit, omdat de zoekopdracht onvolledig was.',
      'fr' => "Cette réponse ne vous a coûté aucun crédit, car la recherche était incomplète.",
      'en' => 'This answer cost you no credit because the search was incomplete.',
      'de' => 'Diese Antwort hat Sie keinen Credit gekostet, weil die Suche unvollständig war.'
    }.freeze

    # Appends the free-answer note to the notice paragraph of `answer`, in
    # `language` (falling back to Dutch like the notice itself). An answer
    # without a notice paragraph is returned untouched: the note only ever
    # rides inside the paragraph that history replay strips, never on its
    # own. A class method because the controller holds the result, not the
    # service, when it decides about the charge.
    def self.with_free_answer_note(answer, language)
      return answer unless answer.is_a?(String)

      note = RETRIEVAL_FREE_ANSWER_NOTES.fetch(language.to_s) { RETRIEVAL_FREE_ANSWER_NOTES.fetch('nl') }
      return answer if answer.include?(note)

      paragraphs = answer.split(/\n{2,}/, -1)
      index = paragraphs.index { |paragraph| paragraph.match?(RETRIEVAL_NOTICE_PARAGRAPH) }
      return answer unless index

      paragraphs[index] = "#{paragraphs[index].rstrip} #{note}"
      paragraphs.join("\n\n")
    end

    # No emoji, article number or link: it is added after the guard chain and
    # must not look like a citation. No cause either: the fan-out establishes
    # only THAT a source was not searched through (see the block comment
    # above), never why. `retry_later:` adds the invitation to ask again.
    def retrieval_notice_text(sources, retry_later: false)
      language = RETRIEVAL_NOTICE_SOURCE_LABELS.key?(@language) ? @language : 'nl'
      labels = RETRIEVAL_NOTICE_SOURCE_LABELS.fetch(language).values_at(*sources.map(&:to_sym)).compact
      # Explicit connectors rather than to_sentence(locale:), which depends on
      # i18n data this app does not ship for every language.
      connector = { 'fr' => ' et ', 'en' => ' and ', 'de' => ' und ' }.fetch(language, ' en ')
      named = [labels[0...-1].join(', ').presence, labels.last].compact.join(connector)

      notice = case language
               when 'fr'
                 "**Attention : la recherche était incomplète.** Une partie de la recherche ne s'est pas terminée : " \
                 "je n'ai pas pu consulter entièrement #{named}, de sorte que cette réponse peut omettre des " \
                 'sources pertinentes.'
               when 'de'
                 '**Hinweis: Die Suche war unvollständig.** Ein Teil der Suche wurde nicht abgeschlossen: ich konnte ' \
                 "#{named} nicht vollständig durchsuchen, diese Antwort kann daher relevante Quellen übersehen."
               when 'en'
                 '**Please note: the search was incomplete.** Part of the search did not finish: I could not fully ' \
                 "search #{named}, so this answer may miss relevant sources."
               else
                 '**Let op: de zoekopdracht was onvolledig.** Een deel van de zoekopdracht is niet afgerond: ik kon ' \
                 "#{named} niet volledig doorzoeken, dus dit antwoord kan relevante bronnen missen."
               end
      retry_later ? "#{notice} #{RETRIEVAL_RETRY_INVITATIONS.fetch(language)}" : notice
    end
  end
end
