# frozen_string_literal: true

module LegalChatbot
  # Bounded parallel retrieval fan-out (FBL-061, extracted verbatim from the
  # orchestrator): one fresh worker thread per source (LegislationSearch
  # keeps a thread-local FTS connection, so jobs must not share threads), a
  # shared monotonic deadline with kill+join of stragglers, deep-frozen
  # detached payloads so a killed worker cannot retain references, retrieval
  # evidence recording (@last_retrieval_searches, read by the pipeline), the
  # degraded-source record behind the user-facing notice
  # (@last_retrieval_degradation), the legislation quality filters and the
  # regional-question gating. Mixed into LegalChatbotService alongside the
  # orchestrator; the *_svc memo readers and is_tax_question? are host
  # methods.
  module SearchFanOut
    extend ActiveSupport::Concern

    PARALLEL_SEARCH_TIMEOUT_SECONDS = 30.0
    COMPLETED_EU_PAYLOAD_SINK = :legal_chatbot_completed_eu_payload_sink

    # A native backend can fail while the independent immutable EU lane has
    # exact evidence (or vice versa). Keep those rows, without converting an
    # incomplete source job into a healthy telemetry/degradation result.
    class PartialSearchFailure < StandardError
      attr_reader :payload, :original_class, :diagnostic_locations

      def initialize(error, payload)
        @payload = payload
        @original_class = error.class.name
        @diagnostic_locations = SearchFanOut.sanitized_error_locations(error)
        super(@original_class)
      end
    end

    # File basenames + line numbers only. Never log exception messages, query
    # text, source bodies, complete paths or framework/request arguments.
    def self.sanitized_error_locations(error)
      Array(error.backtrace_locations).filter_map do |location|
        path = location.path.to_s.tr('\\', '/')
        next unless path.include?('/app/services/legal_chatbot/')

        basename = File.basename(path)
        next unless basename.match?(/\A[a-z_]+\.rb\z/) && location.lineno.positive?

        "#{basename}:#{location.lineno}"
      end.uniq.first(3)
    end

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
      # source => reason, for the sources that were NOT searched properly:
      # timeout | error | saturated, or the reason a completed search reports
      # itself (semantic_unavailable). Only a created job can land here, so a
      # source the user did not select, one that does not apply to the
      # question, or one disabled by its env flag can never be called degraded.
      # Kept apart from search_evidence on purpose: that hash is an exact-key
      # contract shared with the capture and judge scripts.
      #
      # A completed worker can still report a failed internal source, such
      # as Fisconet's unavailable tax database or optional semantic backend.
      # An ordinary empty, healthy result never counts as degraded.
      degraded = {}
      jobs = {}
      research = @research_depth && LegalChatbotService::RESEARCH_DEPTHS.fetch(@research_depth)

      if sources.include?(:legislation)
        # Legislation: via extracted service object. On gesetzguide the German
        # lane (german_lane?, off by default) first asks the German pointer
        # index with the RAW question vector, never HyDE, in the same worker:
        # no new fan-out key, no change to the search_evidence contract. Only
        # the pointers and wording modes hand the rows to the legislation
        # search; shadow mode logs the comparison and leaves the result as it
        # is. A lane that fails or finds nothing gives [] and changes nothing.
        jobs[:legislation] = lambda do
          merge_eu_source_results(:legislation, question) do
            kwargs = { limit: research ? research.fetch(:legislation_candidates) : 15, question: question }
            if research
              kwargs[:keyword_limit] = research.fetch(:keyword_candidates)
              kwargs[:keyword_passes] = research.fetch(:keyword_passes)
              kwargs[:keyword_quota] = [research.fetch(:keyword_candidates), 8].min
            end
            german_pointers = german_article_search_svc.search(question_embedding) if german_lane?
            merge_pointers = german_pointers.present? && german_article_search_svc.merges_pointers?
            kwargs[:german_pointers] = german_pointers if merge_pointers
            rows = legislation_search_svc.search(hyde_embedding, **kwargs)
            shadow = german_pointers.present? && german_article_search_svc.shadow?
            LegalChatbot::GermanArticleSearch.log_shadow_overlap(german_pointers, rows) if shadow
            # Originals hydrated but withheld (either switch in shadow) are
            # compared with their translations in the pool, for the replay.
            german_article_search_svc.try(:log_shadow_originals, rows) if german_lane?
            rows
          end
        end

        # Fisconet: via extracted service object (keyword search over the tax
        # codes; the consolidated BTW/WIB92 texts exist ONLY there)
        if is_tax_question?(question.downcase)
          jobs[:fisconet] = lambda do
            fisconet_search_svc.search(question, question_embedding, limit: research ? research.fetch(:fisconet_candidates) : 4)
          end
        else
          search_evidence[:fisconet][:status] = 'not_applicable'
        end

        # Regional results are useful only for explicit regional subject
        # matter. Avoid injecting title-only regional neighbours into every
        # federal question (a major source of fabricated Codex quotations).
        if regional_question?(question)
          jobs[:regional] = lambda do
            regional_search_svc.search(question_embedding, question: question, limit: research ? research.fetch(:regional_candidates) : 3)
          end
        else
          search_evidence[:regional][:status] = 'not_applicable'
        end
      end

      # Jurisprudence: via extracted service object
      if sources.include?(:jurisprudence)
        jobs[:jurisprudence] = lambda do
          merge_eu_source_results(:jurisprudence, question) do
            jurisprudence_search_svc.search(question_embedding, question: question, limit: research ? research.fetch(:jurisprudence_candidates) : 3)
          end
        end
      end

      # Parliamentary: via extracted service object
      if sources.include?(:parliamentary)
        jobs[:parliamentary] = lambda do
          native_rows = parliamentary_search_svc.search(question_embedding, question: question, limit: research ? research.fetch(:parliamentary_candidates) : 3)
          scope_native_source_results(native_rows, question)
        end
      end

      deadline = monotonic_now + parallel_search_timeout_seconds
      mutex = Mutex.new
      completion_available = ConditionVariable.new
      completions = []
      completed_eu_payloads = {}
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
              payload = Rails.application.executor.wrap do
                Thread.current.thread_variable_set(COMPLETED_EU_PAYLOAD_SINK, lambda do |published_source, eu_payload|
                  next unless published_source == source

                  mutex.synchronize do
                    completed_eu_payloads[source] = eu_payload if monotonic_now <= deadline
                  end
                end)
                detached_search_payload(job.call)
              ensure
                Thread.current.thread_variable_set(COMPLETED_EU_PAYLOAD_SINK, nil)
              end
              finished_at = monotonic_now
              completion = {
                source: source,
                status: 'completed',
                duration_ms: elapsed_milliseconds(worker_started.fetch(source), finished_at),
                timeout: false,
                error: nil,
                payload: payload,
                # Read in the worker, right after its own search: the payload
                # is a frozen array and cannot carry the flag out.
                degradation: search_degradation_for(source),
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
            error_class = e.is_a?(PartialSearchFailure) ? e.original_class : e.class.name
            locations = e.is_a?(PartialSearchFailure) ? e.diagnostic_locations : SearchFanOut.sanitized_error_locations(e)
            diagnostic = locations.empty? ? '' : " at #{locations.join(',')}"
            Rails.logger.error("[Orchestrator] #{source.to_s.capitalize} search failed: #{error_class}#{diagnostic}")
            completion = {
              source: source,
              status: 'error',
              duration_ms: elapsed_milliseconds(worker_started.fetch(source), finished_at),
              timeout: false,
              error: error_class,
              payload: e.is_a?(PartialSearchFailure) ? detached_search_payload(e.payload) : [].freeze,
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
          degraded[source] = completion[:degradation] if completion[:degradation]
          degraded[source] = completion.fetch(:status) unless completion.fetch(:status) == 'completed'
        end
        break if pending.empty? || monotonic_now >= deadline
      end

      pending.each_key do |source|
        degraded[source] = 'timeout'
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
      # Only completed, sealed EU snapshots can survive an unfinished native
      # search. All workers are gone before this coordinator copies them into
      # the response, whose source remains truthfully marked as timed out.
      pending.each_key do |source|
        results[source] = completed_eu_payloads.fetch(source, []).deep_dup
      end

      @last_retrieval_searches = deep_freeze_search_value(search_evidence.deep_dup)
      # In the fixed source order, not in completion order: the notice names
      # the sources in this order.
      @last_retrieval_degradation = deep_freeze_search_value(degraded.slice(*results.keys))
      results
    end

    # What the source's own search reported about itself, or nil. Reads the
    # memo ivar the job has just filled rather than the *_svc reader, and
    # guards with respond_to?: the suites that install fakes set that same
    # ivar, and their fakes have no such reader.
    def search_degradation_for(source)
      svc = instance_variable_get(:"@#{source}_search_svc")
      degradation = svc.retrieval_degradation if svc.respond_to?(:retrieval_degradation)
      eu_degradation = if %i[legislation jurisprudence].include?(source) && @eu_search_svc
                         # Existing injected search fakes retain their no-arg
                         # contract; the real EU lane reports per-source state.
                         reader = @eu_search_svc.method(:retrieval_degradation) if @eu_search_svc.respond_to?(:retrieval_degradation)
                         reader&.arity&.zero? ? reader.call : reader&.call(source)
                       end
      degradation || eu_degradation
    end

    def merge_eu_source_results(source, question)
      failure = nil
      eu_rows = begin
        eu_search_svc.search(question, source: source, exclusive_unit_scope: eu_unit_only_question?(question))
      rescue StandardError => e
        failure = e
        []
      end
      sink = Thread.current.thread_variable_get(COMPLETED_EU_PAYLOAD_SINK)
      if sink && eu_rows.present?
        verified_rows = Array(eu_rows).filter_map { |row| verified_eurlex_corpus_record(row) }
        sink.call(source, detached_search_payload(verified_rows)) unless verified_rows.empty?
      end
      native_rows = begin
        yield
      rescue StandardError => e
        failure ||= e
        []
      end
      rows = scope_native_source_results(native_rows, question) + Array(eu_rows)
      raise PartialSearchFailure.new(failure, rows) if failure

      rows
    end

    def scope_native_source_results(rows, question)
      return Array(rows) unless eu_unit_only_question?(question)

      Array(rows).select do |row|
        %i[pinned viewed selected explicit].any? { |key| [true, 1, 'true', '1'].include?(row[key] || row[key.to_s]) }
      end
    end

    def eu_unit_only_question?(question)
      # A narrowly named EU unit is not a request for Belgian semantic
      # neighbours. Keep deliberate mixed national/EU requests and viewed-law
      # context; this is a scope boundary, not a relaxed similarity threshold.
      EuSearch.unit_only_question?(question, context_numacs: @context_numacs)
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

      # Translations of one provision are not two independent supporting
      # articles and must not consume two slots or satisfy the strong-hit
      # floor twice. Keep the site's preferred wording, not a stitched text.
      articles = retain_final_hybrid_quota(articles, limit: articles.length, lexical_quota: 0)

      # A small relevant set is not permission to restore rejected domains.
      # The title filter already preserves explicit/viewed/pinned provisions;
      # retain its decision even when only one or two sources remain.
      articles = svc.filter_by_title_relevance(articles, question)

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
                   articles.select { |article| high_sim.include?(article) || article[:pinned] || article[:keyword_hit] }
                 else
                   articles.select do |a|
                     a[:similarity].to_f >= 0.35 || a[:pinned] || a[:keyword_hit]
                   end.take(10)
                 end

      # Website compliance needs the identification/order/withdrawal AND
      # exception/cookie/electronic-form pack together. A generic eight-row
      # cut would silently remove complementary governing provisions. This
      # narrowly bounded floor changes no other topic's source budget.
      commercial_pack_size = CommercialWebsiteIntent.article_targets(question).length
      marketplace_pack_size = MarketplaceCivilClaimIntent.article_targets(question).length
      retain_final_hybrid_quota(articles, limit: [8, commercial_pack_size, marketplace_pack_size].max, lexical_quota: 2)
    end

    # Preserve pins first and a small lexical slice after every downstream
    # filter. Otherwise the final take(8) can undo LegislationSearch's hybrid
    # retrieval guarantee.
    def retain_final_hybrid_quota(articles, limit:, lexical_quota:, diversify_injected: false)
      return [] unless limit.positive?

      # Collapse only NL/FR translations with an exact legislative identity.
      # German binding originals, regional regimes and article variants are
      # distinct evidence. Keep literal number separators: 1.2 and 1/2 may
      # be different provisions even though their browser anchors coincide.
      bilingual_groups = articles.group_by do |article|
        language_id = source_field(article, :language_id, 'language_id')
        numac = retrieved_source_numac(article)
        raw_title = source_field(article, :article_title, 'article_title').to_s
        # Annotated titles can denote different paragraph/edition snippets
        # even when their leading article number agrees. Without structured
        # paragraph identity, keeping both is safer than collapsing them.
        next if raw_title.present? && !raw_title.match?(%r{\A\s*Art(?:ikel|icle)?\.?\s*[[:alnum:]][\w/.:-]*\s*\z}i)

        number = source_field(article, :article_number, 'article_number').presence ||
                 raw_title[%r{\bArt(?:ikel|icle)?\.?\s*([[:alnum:]][\w/.:-]*)}i, 1]
        next unless [1, 2].include?(language_id) && numac.present? && number.present?
        next if source_field(article, :source, 'source').present? || source_field(article, :region, 'region').present?

        title_variant = raw_title[TextProcessing::ARTICLE_VARIANT_SUFFIX]
        [numac, strip_article_prefix(number).downcase.delete(' ').sub(/\.+\z/, ''),
         source_field(article, :article_variant, 'article_variant'), title_variant]
      end
      replacements = {}.compare_by_identity
      bilingual_groups.each do |identity, rows|
        next unless identity && rows.map { |row| source_field(row, :language_id, 'language_id') }.uniq.sort == [1, 2]

        preferred = rows.select { |row| source_field(row, :language_id, 'language_id') == @language_id }
                        .max_by { |row| [row[:pinned] ? 1 : 0, row[:similarity].to_f] }
        preferred ||= rows.max_by { |row| [row[:pinned] ? 1 : 0, row[:similarity].to_f] }
        # Flags/ranking record how the provision was found, not new legal
        # wording. Preserve those so a lexical/pinned FR hit does not cease
        # to be lexical/pinned when the same provision's NL text is selected.
        representative = preferred.merge(similarity: rows.map { |row| row[:similarity].to_f }.max)
        representative[:pinned] = true if rows.any? { |row| row[:pinned] }
        representative[:keyword_hit] = true if rows.any? { |row| row[:keyword_hit] }
        representative[:governing_group] = true if rows.any? { |row| LegalChatbot::LegislationSearch.governing_source?(row) }
        # An independently retrieved translation makes the provision real
        # search evidence, even when the preferred-language row was injected.
        representative[:injected] = rows.all? { |row| row[:injected] } if rows.any? { |row| row.key?(:injected) }
        rows.each { |row| replacements[row] = representative }
      end
      seen_representatives = Set.new.compare_by_identity
      articles = articles.filter_map do |article|
        replacement = replacements[article]
        next article unless replacement
        next unless seen_representatives.add?(replacement)

        replacement
      end
      # The explicit governing group (LegislationSearch.governing_source?) is
      # kept whole and once each. It counts toward the limit and the other
      # rows, pins included, share what is left (root 2026-10-19 23:30:47);
      # the kept pins, governing or not, keep their order ahead of the
      # optional rows. Without a governing row this is the quota as before.
      governing = articles.select { |article| LegalChatbot::LegislationSearch.governing_source?(article) }
                          .uniq { |article| [retrieved_source_numac(article), article[:article_title], article[:language_id]] }
      rest = articles.reject { |article| LegalChatbot::LegislationSearch.governing_source?(article) }
      room = [limit - governing.length, 0].max
      pins = rest.select { |article| article[:pinned] }.take(room)
      remaining = rest.reject { |article| pins.include?(article) }
      lexical = remaining.select { |article| article[:keyword_hit] }
                         .take([lexical_quota.clamp(0, limit), room - pins.length].min)
      semantic_pool = remaining.reject { |article| lexical.include?(article) }
      if diversify_injected
        # Core-law injection is bounded fallback evidence, not an independent
        # semantic match. Three heavily boosted fillers from one ancillary
        # code must not crowd the real primary statute out of a five-row
        # context. Pins, exact lexical hits and the viewed/context law retain
        # their existing priority. Surplus fillers remain usable as backfill,
        # so a sparse corpus never loses its only available evidence.
        context_laws = Array(@context_numacs).to_set(&:to_s)
        seen_injected_laws = Set.new
        surplus = []
        semantic_pool = semantic_pool.reject do |article|
          numac = retrieved_source_numac(article)
          next false unless article[:injected] && !article[:keyword_hit] && numac.present? && !context_laws.include?(numac)
          next false if seen_injected_laws.add?(numac)

          surplus << article
          true
        end + surplus
      end
      semantic = semantic_pool.take(room - pins.length - lexical.length)
      original_positions = {}.compare_by_identity
      articles.each_with_index { |article, index| original_positions[article] ||= index }

      (governing + pins + semantic + lexical)
        .sort_by do |article|
          [article[:pinned] ? -Float::INFINITY : -article[:similarity].to_f, original_positions.fetch(article)]
        end
        .take(governing.length + room)
    end

    # Explicit region names always qualify. Generic regionalized subject
    # matter qualifies only for a strong regional-law concept; broad words
    # such as "premie" or "vergunning" alone deliberately do not.
    def regional_question?(question)
      q = question.to_s.downcase
      explicit_region = LegalChatbot::RegionalSearch::REGION_PATTERNS.values.any? { |pattern| q.match?(pattern) } ||
                        q.match?(/\b(?:gewest|région|region|regionaal|regional)\b/i)
      # The same subject decision as the regional selection and the
      # all-regions prompt task (an agricultural lease opened the prompt's
      # all-regions task but not this lane until 2026-10-17).
      regional_subject = LegalChatbot::RegionalSearch.regional_subject_question?(question)

      # An airport/destination name is not a request for that region's law.
      # In the flight-compensation replay, "Brussel" alone injected unrelated
      # regional circulars and disability rules. Keep actual regional subjects
      # and explicit regional-law requests, including deliberately mixed asks.
      if !regional_subject && EuTopicIntent.plan(question)&.fetch(:topic) == :flight_disruption
        regional_law_request = q.match?(/
          \b(?:gewest\p{L}*|r[ée]gion\p{L}*|ordonnantie\p{L}*|ordonnance\p{L}*|ordonnanz\p{L}*|
               decreet\p{L}*|décret\p{L}*|dekret\p{L}*|milieu\p{L}*|omgevings\p{L}*|
               geluidshinder|geluidsoverlast|noise|bruit\p{L}*|fluglärm|lärm\p{L}*|environment\p{L}*|umwelt\p{L}*)\b
        /ixu)
        selected_legal_source = Array(@context_numacs).any? || q.match?(/\b\d{4}(?:[a-z]\d{5}|\d{6})\b/i)
        return false unless regional_law_request || selected_legal_source
      end

      explicit_region || regional_subject
    end

    # One predicate, shared with the German question translation, which must
    # not turn a refused question into one that is answered.
    def unsupported_regional_corpus_question?(question)
      LegalChatbot::RegionalSearch.unsupported_corpus_question?(question)
    end
  end
end
