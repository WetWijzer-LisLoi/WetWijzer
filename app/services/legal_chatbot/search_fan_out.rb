# frozen_string_literal: true

module LegalChatbot
  # Bounded parallel retrieval fan-out (FBL-061, extracted verbatim from the
  # orchestrator): one fresh worker thread per source (LegislationSearch
  # keeps a thread-local FTS connection, so jobs must not share threads), a
  # shared monotonic deadline with kill+join of stragglers, deep-frozen
  # detached payloads so a killed worker cannot retain references, retrieval
  # evidence recording (@last_retrieval_searches, read by the pipeline), the
  # legislation quality filters and the regional-question gating. Mixed into
  # LegalChatbotService alongside the orchestrator; the *_svc memo readers
  # and is_tax_question? are host methods.
  module SearchFanOut
    extend ActiveSupport::Concern

    PARALLEL_SEARCH_TIMEOUT_SECONDS = 30.0

    # FBL-065: one process-wide cap on concurrently RUNNING retrieval
    # workers (default 16 = ~3 saturated asks' worth). A worker that cannot
    # get a slot inside the shared deadline reports 'saturated' for its
    # source and the ask degrades per-source, exactly like an error - it
    # never queues unbounded threads behind a stampede.
    def self.worker_cap
      value = Integer(ENV.fetch('CHATBOT_SEARCH_WORKER_CAP', '16'), exception: false)
      value&.positive? ? value : 16
    end

    def self.worker_semaphore
      @worker_semaphore ||= Concurrent::Semaphore.new(worker_cap)
    end

    # Test hook: rebuild after changing CHATBOT_SEARCH_WORKER_CAP.
    def self.reset_worker_semaphore!
      @worker_semaphore = nil
    end

    # Execute searches in parallel via extracted service objects.
    # All 5 search sources use their own service objects.
    def execute_parallel_searches(sources, question, question_embedding, hyde_embedding)
      results = { legislation: [], jurisprudence: [], parliamentary: [], fisconet: [], regional: [] }
      search_evidence = ChatbotQualityEvidence.empty_retrieval_searches
      jobs = {}

      if sources.include?(:legislation)
        # Legislation: via extracted service object
        jobs[:legislation] = lambda do
          legislation_search_svc.search(hyde_embedding, limit: 15, question: question)
        end

        # Fisconet: via extracted service object (keyword search over the tax
        # codes; the consolidated BTW/WIB92 texts exist ONLY there)
        if is_tax_question?(question.downcase)
          jobs[:fisconet] = lambda do
            fisconet_search_svc.search(question, question_embedding, limit: 4)
          end
        else
          search_evidence[:fisconet][:status] = 'not_applicable'
        end

        # Regional results are useful only for explicit regional subject
        # matter. Avoid injecting title-only regional neighbours into every
        # federal question (a major source of fabricated Codex quotations).
        if regional_question?(question)
          jobs[:regional] = lambda do
            regional_search_svc.search(question_embedding, question: question, limit: 3)
          end
        else
          search_evidence[:regional][:status] = 'not_applicable'
        end
      end

      # Jurisprudence: via extracted service object
      if sources.include?(:jurisprudence)
        jobs[:jurisprudence] = lambda do
          jurisprudence_search_svc.search(question_embedding, limit: 3)
        end
      end

      # Parliamentary: via extracted service object
      if sources.include?(:parliamentary)
        jobs[:parliamentary] = lambda do
          parliamentary_search_svc.search(question_embedding, limit: 3)
        end
      end

      deadline = monotonic_now + parallel_search_timeout_seconds
      mutex = Mutex.new
      completion_available = ConditionVariable.new
      completions = []
      worker_started = {}
      threads = jobs.to_h do |source, job|
        worker_started[source] = monotonic_now
        thread = Thread.new do
          completion = nil
          acquired = false
          begin
            # FBL-065: a slot must be free before the corpus work starts; the
            # wait is bounded by the remaining shared deadline MINUS a small
            # epsilon, so a starved worker reports 'saturated' just before
            # the coordinator's own cutoff would mislabel it 'timeout'.
            acquired = SearchFanOut.worker_semaphore.try_acquire(1, [deadline - monotonic_now - 0.1, 0].max)
            if acquired
              payload = Rails.application.executor.wrap { detached_search_payload(job.call) }
              finished_at = monotonic_now
              completion = {
                source: source,
                status: 'completed',
                duration_ms: elapsed_milliseconds(worker_started.fetch(source), finished_at),
                timeout: false,
                error: nil,
                payload: payload,
                finished_at: finished_at
              }.freeze
            else
              finished_at = monotonic_now
              Rails.logger.warn("[Orchestrator] #{source.to_s.capitalize} search refused: worker cap saturated")
              completion = {
                source: source,
                status: 'saturated',
                duration_ms: elapsed_milliseconds(worker_started.fetch(source), finished_at),
                timeout: false,
                error: 'worker_cap_saturated',
                payload: [].freeze,
                finished_at: finished_at
              }.freeze
            end
          rescue StandardError => e
            finished_at = monotonic_now
            Rails.logger.error("[Orchestrator] #{source.to_s.capitalize} search failed: #{e.class}")
            completion = {
              source: source,
              status: 'error',
              duration_ms: elapsed_milliseconds(worker_started.fetch(source), finished_at),
              timeout: false,
              error: e.class.name,
              payload: [].freeze,
              finished_at: finished_at
            }.freeze
          ensure
            SearchFanOut.worker_semaphore.release if acquired
            release_search_connection
            if completion
              mutex.synchronize do
                completions << completion
                completion_available.broadcast
              end
            end
          end
        end
        thread.report_on_exception = false
        [source, thread]
      end

      pending = jobs.keys.to_h { |source| [source, true] }
      loop do
        ready = mutex.synchronize do
          while completions.empty? && pending.any?
            remaining = deadline - monotonic_now
            break unless remaining.positive?

            completion_available.wait(mutex, remaining)
          end
          completions.shift(completions.length)
        end

        ready.each do |completion|
          source = completion.fetch(:source)
          next unless pending.key?(source)
          next if completion.fetch(:finished_at) > deadline

          pending.delete(source)
          results[source] = completion.fetch(:payload).deep_dup
          search_evidence[source] = completion.slice(:status, :duration_ms, :timeout, :error)
        end
        break if pending.empty? || monotonic_now >= deadline
      end

      pending.each_key do |source|
        search_evidence[source] = {
          status: 'timeout',
          duration_ms: elapsed_milliseconds(worker_started.fetch(source), deadline),
          timeout: true,
          error: 'deadline_exceeded'
        }
        Rails.logger.error("[Orchestrator] #{source.to_s.capitalize} search exceeded the shared deadline")
        thread = threads.fetch(source)
        thread.kill if thread.alive?
      end
      # A timed-out worker must never retain a reference to the response hash.
      # Join every cancelled worker before returning. Only this coordinator
      # mutates results, so no retrieval work remains alive after handoff.
      threads.each_value(&:join)

      @last_retrieval_searches = deep_freeze_search_value(search_evidence.deep_dup)
      results
    end

    def parallel_search_timeout_seconds
      configured = Float(ENV.fetch('CHATBOT_PARALLEL_SEARCH_TIMEOUT_SECONDS', PARALLEL_SEARCH_TIMEOUT_SECONDS))
      configured.positive? ? configured : PARALLEL_SEARCH_TIMEOUT_SECONDS
    rescue ArgumentError, TypeError
      PARALLEL_SEARCH_TIMEOUT_SECONDS
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_milliseconds(start_time, end_time)
      [((end_time - start_time) * 1000).round, 0].max
    end

    def detached_search_payload(value)
      deep_freeze_search_value(Array(value).deep_dup)
    end

    def deep_freeze_search_value(value)
      case value
      when Hash
        value.each do |key, nested|
          deep_freeze_search_value(key)
          deep_freeze_search_value(nested)
        end
      when Array
        value.each { |nested| deep_freeze_search_value(nested) }
      end
      value.freeze
    end

    def release_search_connection
      ActiveRecord::Base.connection_pool.release_connection
    rescue StandardError => e
      Rails.logger.warn("[Orchestrator] Search connection release failed: #{e.class}")
    end

    # Apply the title/similarity quality filters after LegislationSearch has
    # already fused FAISS, FTS, core-law boosts, and article pins.
    def apply_legislation_quality_filters(articles, question)
      svc = legislation_search_svc

      filtered = svc.filter_by_title_relevance(articles, question)
      articles = filtered if filtered.length >= 3

      min_similarity = 0.50
      high_sim = articles.select { |a| a[:similarity] >= min_similarity }
      # The old fallback (`articles.take(10)`) waived the floor entirely
      # whenever fewer than 3 articles cleared it - i.e. precisely when
      # retrieval was at its noisiest, the top 10 sub-threshold articles went
      # to the LLM unfiltered. The 2026-07-29 judged spot check traced the
      # wrong-subtopic and niche-as-general-rule families (~13 of 45
      # delivered-but-POOR answers) to answers built from exactly such
      # neighbouring-domain context. The fallback now keeps a weaker 0.35
      # floor plus everything pinned or keyword-matched; when NOTHING clears
      # that, the model legitimately gets no legislation context and says the
      # corpus does not cover the topic, which the owner accepted (decision A,
      # docs/ops/legal-merit-fixes-2026-08-03.md) as more honest than an
      # answer press-ganged from adjacent domains.
      articles = if high_sim.length >= 3
                   high_sim
                 else
                   articles.select do |a|
                     a[:similarity].to_f >= 0.35 || a[:pinned] || a[:keyword_hit]
                   end.take(10)
                 end

      retain_final_hybrid_quota(articles, limit: 8, lexical_quota: 2)
    end

    # Preserve pins first and a small lexical slice after every downstream
    # filter. Otherwise the final take(8) can undo LegislationSearch's hybrid
    # retrieval guarantee.
    def retain_final_hybrid_quota(articles, limit:, lexical_quota:)
      pins = articles.select { |article| article[:pinned] }.take(limit)
      remaining = articles.reject { |article| pins.include?(article) }
      lexical = remaining.select { |article| article[:keyword_hit] }
                         .take([lexical_quota, limit - pins.length].min)
      semantic = remaining.reject { |article| lexical.include?(article) }
                          .take(limit - pins.length - lexical.length)

      (pins + semantic + lexical)
        .sort_by { |article| article[:pinned] ? -Float::INFINITY : -article[:similarity].to_f }
        .take(limit)
    end

    # Explicit region names always qualify. Generic regionalized subject
    # matter qualifies only for a strong regional-law concept; broad words
    # such as "premie" or "vergunning" alone deliberately do not.
    def regional_question?(question)
      q = question.to_s.downcase
      explicit_region = LegalChatbot::RegionalSearch::REGION_PATTERNS.values.any? { |pattern| q.match?(pattern) } ||
                        q.match?(/\b(?:gewest|région|region|regionaal|regional)\b/i)
      regional_subject = [
        LegalChatbot::LegislationSearch::REGIONAL_TAX_SUBJECT_PATTERN,
        LegalChatbot::LegislationSearch::REGIONAL_TAX_GIFT_CONTEXT_PATTERN,
        LegalChatbot::LegislationSearch::REGIONAL_TAX_SUCCESSION_CONTEXT_PATTERN,
        LegalChatbot::LegislationSearch::REGIONAL_FAMILY_BENEFIT_PATTERN,
        LegalChatbot::LegislationSearch::REGIONAL_HOUSING_SUBJECT_PATTERN,
        LegalChatbot::LegislationSearch::REGIONAL_PLANNING_SUBJECT_PATTERN
      ].any? { |pattern| q.match?(pattern) }
      regional_subject ||= q.match?(/\b(?:epc|peb|vdab|forem|actiris)\b/i)

      explicit_region || regional_subject
    end

    def unsupported_regional_corpus_question?(question)
      q = question.to_s
      q.match?(LegalChatbot::RegionalSearch::UNSUPPORTED_GERMAN_COMMUNITY_PATTERN) &&
        q.match?(/\b(?:groeipakket|kinderbijslag|allocations?\s+familiales|kindergeld|child\s+benefit|family\s+allowance)\b/i)
    end
  end
end
