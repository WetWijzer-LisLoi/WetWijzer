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

      # Parallel multi-source search via extracted service objects
      all_results = execute_parallel_searches(sources, question, question_embedding, hyde_embedding)
      retrieval_searches = @last_retrieval_searches || ChatbotQualityEvidence.empty_retrieval_searches
      t_search = ((Time.current - phase_start) * 1000).round
      phase_start = Time.current

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
        # laws DB) — one snippet is rarely enough to answer a tax question
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
        return result
      end

      # Build combined context via service
      context = build_combined_context_from_db(
        leg_articles,
        jur_cases,
        parl_docs,
        tax_articles,
        regional_docs,
        max_article_chars: max_article_chars,
        authoritative_docs: authoritative_docs
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
            max_article_chars: max_article_chars, authoritative_docs: authoritative_docs
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
              max_article_chars: max_article_chars, authoritative_docs: authoritative_docs
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
        # the offending references — the exact data needed to decide whether a
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
        # so they must go through their services' own formatters — routing them
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
      # CitationGuard rejection means no verified legal answer was delivered.
      # Mark it as an error so every controller path refunds/skips the charge;
      # the localized message remains the user-facing explanation.
      mark_citation_guard_failure!(result)
      if @include_quality_evidence
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
    # tiers sometimes slugify a law title into /laws/btw-wetboek — a route
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
    MARKDOWN_BLOCKQUOTE_PATTERN = /(?:^[ ]{0,3}>[^\n]*(?:\n|\z))+/.freeze
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
  end
end
