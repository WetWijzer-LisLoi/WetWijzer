# frozen_string_literal: true

require 'digest'
require 'json'
require 'net/http'

module LegalChatbot
  # The German lane of the chatbot on gesetzguide.be (D6 of
  # docs/ops/german-corpus-plan-2026-09-27.md).
  #
  # The German articles (language_id 3) have their own FAISS index, served by
  # the faiss-german unit on 127.0.0.1:8771. Each sidecar row has a row_kind:
  #
  # 'pointer' (every row of a legacy generation, which has no row_kind): the
  #   German text is a translation or coordination, and the row names the one
  #   binding French article it translates (fr_article_id, fr_numac,
  #   fr_article_title), the sha256 of that French text at build time, and a
  #   currency verdict. The hit becomes that French row in the shape
  #   search_faiss returns (legislation_search.rb), so the model's evidence,
  #   citation, link and source card are the current French row. Hydration is
  #   .where(id:, language_id: 2) and nothing else.
  #
  # 'original': the German text IS the law, a decree of the German-speaking
  #   Community or of its government in its original German publication
  #   (GermanTextProvenance::BINDING_ORIGINAL_SOURCE_METHODS; owner decision
  #   2026-09-28). The hit becomes the LIVE language 3 row of that article,
  #   read through the only language 3 query of the chatbot, which admits
  #   binding originals and nothing else (resolve_originals). The row carries
  #   :german_original, which the context builder, QuoteGuard, CitationGuard
  #   and LinkGuard require before they treat a German row as evidence.
  #
  # Staged switch, GERMAN_LANE_MODE (default off):
  #   off      - never called (LegalChatbotService#german_lane? is false)
  #   shadow   - the index is queried and the outcome logged; the answer is
  #              unchanged (the fan-out does not pass the rows on)
  #   pointers - the French rows are merged into the legislation result
  #   wording  - as pointers, plus the German wording rides along as
  #              german_evidence[:wording] for the context builder
  #
  # Second switch, GERMAN_ORIGINALS_MODE (default off), for the originals:
  #   off    - an original hit is never hydrated: no language 3 row is read
  #   shadow - originals are hydrated and logged, never returned
  #   on     - originals are returned beside the pointers, but they reach the
  #            answer only when GERMAN_LANE_MODE is pointers or wording (the
  #            fan-out passes rows on only then); with GERMAN_LANE_MODE=shadow
  #            they are hydrated and logged as in shadow
  # GERMAN_ORIGINALS_MODE=off (and a Puma stop/start) is the rollback: the
  # lane is then exactly the pointer lane, with no rebuild.
  #
  # The wording of a pointer is never stored under a key QuoteGuard reads
  # (article_text, text, full_text, content; answer_guards.rb:51), so a
  # German translation can never verify as a quotation of binding text. An
  # original's article_text is the binding German text, so a verbatim German
  # quote from it verifies.
  #
  # Any failure (refused, timeout, HTTP error, a response without the sidecar
  # fields or a hit that breaks the rules of its kind) logs
  # '[GermanLane] unavailable: <class>' and returns [], so the ask proceeds
  # exactly as without the lane. Log lines carry counts, ids, similarities
  # and verdicts only: never the question, never the vector.
  class GermanArticleSearch
    include TextProcessing

    class ServiceError < StandardError; end

    MODE_ENV = 'GERMAN_LANE_MODE'
    MODES = %w[off shadow pointers wording].freeze
    DEFAULT_MODE = 'off'
    ORIGINALS_MODE_ENV = 'GERMAN_ORIGINALS_MODE'
    ORIGINALS_MODES = %w[off shadow on].freeze
    DEFAULT_ORIGINALS_MODE = 'off'
    URL_ENV = 'GERMAN_FAISS_URL'
    DEFAULT_URL = 'http://127.0.0.1:8771'
    OPEN_TIMEOUT_SECONDS = 1
    READ_TIMEOUT_SECONDS = 3
    # Pointers and originals compete in one top-k (one index, one similarity
    # scale); faiss_serve caps the limit at its MAX_RESULTS.
    SEARCH_LIMIT = 30
    MAX_POINTERS = 3
    MAX_ORIGINALS = 3
    FRENCH_LANGUAGE_ID = 2
    GERMAN_LANGUAGE_ID = 3
    LOG_TAG = '[GermanLane]'

    ROW_POINTER = 'pointer'
    ROW_ORIGINAL = 'original'
    ROW_KINDS = [ROW_POINTER, ROW_ORIGINAL].freeze

    # Placeholders until the calibration replay (scripts/ops/german_lane_replay.rb)
    # sets them from the table: the floor starts at the title-filter bypass
    # (legislation_search.rb, similarity >= 0.55), the weight at 1.0 (no
    # same-language bonus, unlike search_faiss's x1.20). MODIFICATION_POINTERS
    # keeps or drops pointers whose German text is an amending act
    # (sidecar is_modification), without a rebuild.
    MIN_SIMILARITY = 0.55
    WEIGHT = 1.0
    MODIFICATION_POINTERS = true

    # The same placeholders for the originals, until the replay's
    # 'originals on' column sets them. ORIGINAL_WEIGHT is taken from the
    # median main/German similarity over (FR translation, original) pairs.
    ORIGINAL_MIN_SIMILARITY = 0.55
    ORIGINAL_WEIGHT = 1.0

    # The prompt shows at most this much of the wording; the sidecar stores
    # up to 2,000 characters so the limit can rise without a rebuild.
    WORDING_MAX_CHARS = 1200

    # At most this many later amending acts ride along with an original (the
    # context lists them, then "und N weitere"); the sidecar keeps them all.
    AMENDED_BY_SHOWN = 5

    # The sidecar contract (faiss-german.service --require-meta-fields): the
    # fields both kinds fill, then the fields of a pointer only. An original
    # has all four POINTER_FIELDS null, a text_sha256 of the German text at
    # build time, a binding source_method and one of ORIGINAL_CURRENCIES.
    COMMON_FIELDS = %w[
      article_id german_numac german_article_title currency source_method publication_date
    ].freeze
    POINTER_FIELDS = %w[fr_article_id fr_numac fr_article_title fr_text_sha256].freeze
    # The builder's EMBEDDABLE_SOURCE_METHODS (german_article_map.py): the
    # translations and coordinations a pointer may come from.
    POINTER_SOURCE_METHODS = %w[
      staatsblatt_de:official_translation staatsblatt_de:official_translation_extracts
      staatsblatt_de:unofficial_coordination staatsblatt_de:unofficial_coordination_extracts
    ].freeze
    AS_PUBLISHED = 'as_published'
    AMENDED = 'amended'
    ORIGINAL_CURRENCIES = [AS_PUBLISHED, AMENDED].freeze

    # The select of legislation_search.rb#search_faiss, so a pointer row
    # carries the same law title and flags as any other French row.
    HYDRATION_SELECT = 'articles.*, COALESCE(legislation.short_title, legislation.title) as law_title, ' \
                       'legislation.date, legislation.is_abolished, legislation.is_modification'
    CONTENTS_JOIN = 'LEFT JOIN contents ON articles.content_numac = contents.legislation_numac ' \
                    'AND articles.language_id = contents.language_id'
    LEGISLATION_JOIN = 'LEFT JOIN legislation ON contents.legislation_numac = legislation.numac ' \
                       'AND contents.language_id = legislation.language_id'
    # The same select for an original, plus the live provenance of its act.
    ORIGINAL_HYDRATION_SELECT = "#{HYDRATION_SELECT}, legislation.source_method AS legislation_source_method".freeze

    class << self
      # The configured mode, read at call time so an env change needs no
      # process restart in tests; production still restarts Puma on env edits.
      def mode
        value = ENV.fetch(MODE_ENV, DEFAULT_MODE).to_s.strip.downcase
        MODES.include?(value) ? value : DEFAULT_MODE
      end

      def active?(mode = self.mode)
        mode != 'off'
      end

      def shadow?(mode = self.mode)
        mode == 'shadow'
      end

      def merges_pointers?(mode = self.mode)
        %w[pointers wording].include?(mode)
      end

      def wording?(mode = self.mode)
        mode == 'wording'
      end

      # GERMAN_ORIGINALS_MODE, read at call time like #mode.
      def originals_mode
        value = ENV.fetch(ORIGINALS_MODE_ENV, DEFAULT_ORIGINALS_MODE).to_s.strip.downcase
        ORIGINALS_MODES.include?(value) ? value : DEFAULT_ORIGINALS_MODE
      end

      # True only with GERMAN_ORIGINALS_MODE=on. The context builder and the
      # guards require it (plus the lane flag of the service and a hydrated
      # :german_original) before a German row counts as evidence.
      def originals_on?(originals_mode = self.originals_mode)
        originals_mode == 'on'
      end

      def originals_shadow?(originals_mode = self.originals_mode)
        originals_mode == 'shadow'
      end

      def url
        ENV.fetch(URL_ENV, DEFAULT_URL)
      end

      # Shadow mode's comparison line: for the French rows both the main
      # index and the German index found, the main similarity (as the
      # pipeline ranks it) next to the German cosine. The calibration replay
      # takes the median of the same ratio to set WEIGHT.
      def log_shadow_overlap(pointers, legislation_rows)
        pointers = Array(pointers)
        return if pointers.empty?

        main_by_id = Array(legislation_rows).each_with_object({}) do |row, memo|
          memo[row[:id]] ||= row[:similarity].to_f if row.is_a?(Hash)
        end
        pairs = pointers.filter_map do |pointer|
          main = main_by_id[pointer[:id]]
          next unless main

          german = pointer.dig(:german_evidence, :similarity).to_f
          "#{pointer[:id]}:#{main.round(3)}/#{german.round(3)}"
        end
        Rails.logger.info(
          "#{LOG_TAG} shadow overlap: both=#{pairs.size} of #{pointers.size} pointers " \
          "main_rows=#{main_by_id.size} pairs=#{pairs.join(',')}"
        )
      end
    end

    # The originals this instance's last search hydrated but did not return
    # (either switch in shadow), for #log_shadow_originals.
    attr_reader :mode, :originals_mode, :shadow_originals

    def initialize(mode: self.class.mode, originals_mode: self.class.originals_mode)
      @mode = MODES.include?(mode.to_s) ? mode.to_s : DEFAULT_MODE
      @originals_mode = ORIGINALS_MODES.include?(originals_mode.to_s) ? originals_mode.to_s : DEFAULT_ORIGINALS_MODE
      @shadow_originals = []
    end

    def active?
      self.class.active?(@mode)
    end

    def shadow?
      self.class.shadow?(@mode)
    end

    def merges_pointers?
      self.class.merges_pointers?(@mode)
    end

    def wording?
      self.class.wording?(@mode)
    end

    # Originals are hydrated (a language 3 read) unless their switch is off.
    def hydrates_originals?
      @originals_mode != 'off'
    end

    # Originals leave this class only with both switches forward: the lane
    # merging rows into the answer and GERMAN_ORIGINALS_MODE=on.
    def returns_originals?
      merges_pointers? && self.class.originals_on?(@originals_mode)
    end

    # The raw question vector (never HyDE) in; out, at most MAX_POINTERS
    # French rows, each in the search_faiss shape plus :german_evidence,
    # then (both switches forward) at most MAX_ORIGINALS binding German rows,
    # each in the same shape plus :german_original.
    # [] when the lane is off, when nothing qualifies, or on any failure.
    def search(question_embedding)
      @shadow_originals = []
      return [] unless active?

      hits = fetch_hits(question_embedding)
      pointer_hits, original_hits = hits.partition { |hit| hit[:row_kind] == ROW_POINTER }
      pointers = collapse(pointer_hits)
      above_floor = pointers.select { |pointer| pointer[:similarity] >= MIN_SIMILARITY }
      rows, dropped = hydrate(above_floor)
      kept = rows.take(MAX_POINTERS)
      originals = resolve_originals(original_hits)
      log_summary(hits: pointer_hits, pointers: pointers, above_floor: above_floor, rows: rows, kept: kept,
                  dropped: dropped, originals: originals)
      return kept + originals[:kept] if returns_originals?

      @shadow_originals = originals[:kept]
      kept
    rescue StandardError => e
      # Class only, plus our own message for ServiceError (a status code or a
      # field name, never response text): a provider message can echo a body.
      detail = e.is_a?(ServiceError) ? " (#{e.message})" : ''
      Rails.logger.warn("#{LOG_TAG} unavailable: #{e.class}#{detail}")
      []
    end

    private

    # ------------------------------------------------------------------
    # faiss-german (port 8771)
    # ------------------------------------------------------------------

    def fetch_hits(question_embedding)
      uri = URI("#{self.class.url}/search")
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = { embedding: question_embedding, limit: SEARCH_LIMIT }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 open_timeout: OPEN_TIMEOUT_SECONDS,
                                 read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.request(request)
      end
      raise ServiceError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      results = JSON.parse(response.body)['results']
      raise ServiceError, 'no results array' unless results.is_a?(Array)

      results.map { |result| normalize_hit(result) }
    end

    # One hit of faiss_serve's /search: the identity keys (article_id and
    # friends) plus every sidecar column except row_id, NULL as nil. The
    # sidecar contract is fixed; a hit without it, or one that breaks the
    # rules of its kind, means a broken builder or the wrong service on 8771,
    # so the whole response is refused rather than repaired. A hit without
    # row_kind comes from a legacy (pointer-only) generation.
    def normalize_hit(result)
      raise ServiceError, 'hit is not an object' unless result.is_a?(Hash)

      kind = result['row_kind'].to_s.strip.presence || ROW_POINTER
      raise ServiceError, 'unknown row_kind' unless ROW_KINDS.include?(kind)

      missing = COMMON_FIELDS.select { |field| blank_field?(result, field) }
      raise ServiceError, "missing sidecar field #{missing.first}" if missing.any?

      kind == ROW_ORIGINAL ? normalize_original(result) : normalize_pointer(result)
    end

    def blank_field?(result, field)
      result[field].nil? || result[field].to_s.strip.empty?
    end

    def normalize_pointer(result)
      missing = POINTER_FIELDS.select { |field| blank_field?(result, field) }
      raise ServiceError, "missing sidecar field #{missing.first}" if missing.any?
      raise ServiceError, 'pointer with a source_method outside the translations' unless POINTER_SOURCE_METHODS.include?(result['source_method'].to_s)

      {
        row_kind: ROW_POINTER,
        german_article_id: Integer(result['article_id']),
        fr_article_id: Integer(result['fr_article_id']),
        fr_numac: result['fr_numac'].to_s,
        fr_article_title: result['fr_article_title'].to_s,
        fr_text_sha256: result['fr_text_sha256'].to_s.strip.downcase,
        currency: result['currency'].to_s,
        source_method: result['source_method'].to_s,
        publication_date: result['publication_date'].to_s,
        is_modification: [1, true, '1'].include?(result['is_modification']),
        wording: result['wording'].to_s.presence,
        similarity: Float(result['similarity'])
      }
    end

    # An original names no French article: every fr_* is null. Its identity
    # is the German row itself (article_id and the natural key german_numac
    # plus german_article_title), the sha256 of its German text at build
    # time, and the currency the builder read from later amending decrees.
    def normalize_original(result)
      raise ServiceError, 'original with a French field' if POINTER_FIELDS.any? { |field| !result[field].nil? }
      raise ServiceError, 'original without text_sha256' if blank_field?(result, 'text_sha256')
      raise ServiceError, 'original with a non-binding source_method' unless GermanTextProvenance.binding_original?(result['source_method'])
      raise ServiceError, 'original with an unknown currency' unless ORIGINAL_CURRENCIES.include?(result['currency'].to_s)

      {
        row_kind: ROW_ORIGINAL,
        german_article_id: Integer(result['article_id']),
        german_numac: result['german_numac'].to_s,
        german_article_title: result['german_article_title'].to_s,
        text_sha256: result['text_sha256'].to_s.strip.downcase,
        currency: result['currency'].to_s,
        source_method: result['source_method'].to_s,
        publication_date: result['publication_date'].to_s,
        act_date: result['act_date'].to_s.presence,
        original_kind: result['original_kind'].to_s.presence,
        amended_by: amended_by_list(result),
        is_modification: [1, true, '1'].include?(result['is_modification']),
        similarity: Float(result['similarity'])
      }
    end

    # The sidecar's amended_by: for 'amended' a JSON array, sorted by date, of
    # {numac, date, publication_date, kind, verb}; null for 'as_published'.
    # An 'amended' row without a readable non-empty list breaks the contract.
    def amended_by_list(result)
      return [] unless result['currency'].to_s == AMENDED

      list = result['amended_by'].is_a?(String) ? JSON.parse(result['amended_by']) : result['amended_by']
      valid = list.is_a?(Array) && list.any? && list.all? { |entry| entry.is_a?(Hash) && entry['numac'].present? }
      raise ServiceError, 'amended original without amended_by' unless valid

      list.map { |entry| entry.slice('numac', 'date', 'publication_date', 'kind', 'verb').symbolize_keys }
    rescue JSON::ParserError
      raise ServiceError, 'amended original without amended_by'
    end

    # One pointer per French article. Chunks of one German text and several
    # German texts of one act (a translation and a later coordination) all
    # point to the same French row: keep the maximum similarity, and take
    # the identity (currency, sha, date, method) from the newest current
    # text that carries wording, else from the best hit.
    def collapse(hits)
      hits.group_by { |hit| hit[:fr_article_id] }.map do |_fr_id, group|
        best = group.max_by { |hit| hit[:similarity] }
        current = group.select { |hit| hit[:currency] == 'current' && hit[:wording] }
                       .max_by { |hit| hit[:publication_date] }
        (current || best).merge(similarity: best[:similarity])
      end.sort_by { |pointer| -pointer[:similarity] }
    end

    # ------------------------------------------------------------------
    # French rows (language 2 only)
    # ------------------------------------------------------------------

    def hydrate(pointers)
      dropped = Hash.new(0)
      return [[], dropped] if pointers.empty?

      articles_by_id = Article
                       .select(HYDRATION_SELECT)
                       .joins(CONTENTS_JOIN)
                       .joins(LEGISLATION_JOIN)
                       .where(id: pointers.map { |pointer| pointer[:fr_article_id] }, language_id: FRENCH_LANGUAGE_ID)
                       .index_by(&:id)

      rows = pointers.filter_map do |pointer|
        article = articles_by_id[pointer[:fr_article_id]]
        # Missing: the id is gone, or holds a language 1 or 3 row.
        unless article
          dropped[:missing] += 1
          next
        end
        # articles has no AUTOINCREMENT, so an id can be reused by another
        # row: the natural key must still be the one the sidecar recorded.
        unless article.content_numac == pointer[:fr_numac] && article.article_title == pointer[:fr_article_title]
          dropped[:key] += 1
          next
        end
        if article.try(:is_abolished) == 1
          dropped[:abolished] += 1
          next
        end
        if pointer[:is_modification] && !MODIFICATION_POINTERS
          dropped[:modification] += 1
          next
        end

        verified = wording_verified?(pointer, article)
        {
          id: article.id,
          numac: article.content_numac,
          law_title: article.law_title || lookup_law_title(article.content_numac, article.language_id) || "Législation #{article.content_numac}",
          article_title: article.article_title,
          article_text: article.article_text,
          article_variant: article.try(:article_variant),
          language_id: article.language_id,
          similarity: pointer[:similarity] * WEIGHT,
          is_abolished: false,
          is_modification: article.try(:is_modification) == 1,
          german_evidence: {
            german_article_id: pointer[:german_article_id],
            similarity: pointer[:similarity],
            currency: pointer[:currency],
            source_method: pointer[:source_method],
            publication_date: pointer[:publication_date],
            is_modification: pointer[:is_modification],
            wording_verified: verified,
            wording: verified && wording? ? pointer[:wording] : nil
          }
        }
      end

      [rows, dropped]
    end

    # The wording may be shown only for a build-time 'current' verdict whose
    # French text is still the one the verdict was made on (the live text
    # hashes to the sidecar's fr_text_sha256).
    def wording_verified?(pointer, article)
      return false unless pointer[:currency] == 'current'

      Digest::SHA256.hexdigest(article.article_text.to_s) == pointer[:fr_text_sha256]
    end

    # ------------------------------------------------------------------
    # Binding German originals (language 3, binding source methods only)
    # ------------------------------------------------------------------

    # The original hits of one response in; out, what became of them:
    # {hits:, candidates:, above_floor:, hydrated:, kept:, dropped:}. With
    # GERMAN_ORIGINALS_MODE=off nothing is hydrated, so no language 3 row is
    # read at all.
    def resolve_originals(hits)
      outcome = { hits: hits.size, candidates: 0, above_floor: 0, hydrated: 0, kept: [], dropped: {} }
      return outcome if hits.empty? || !hydrates_originals?

      candidates = collapse_originals(hits)
      above_floor = candidates.select { |original| original[:similarity] >= ORIGINAL_MIN_SIMILARITY }
      rows, dropped = hydrate_originals(above_floor)
      outcome.merge(candidates: candidates.size, above_floor: above_floor.size, hydrated: rows.size,
                    kept: rows.take(MAX_ORIGINALS), dropped: dropped)
    end

    # The chunks of one long article ('[Teil N] ') are one original: the
    # best chunk, whose sidecar fields all chunks share, at the maximum
    # similarity.
    def collapse_originals(hits)
      hits.group_by { |hit| hit[:german_article_id] }
          .map { |_id, group| group.max_by { |hit| hit[:similarity] } }
          .sort_by { |original| -original[:similarity] }
    end

    # The chatbot's only read of a language 3 row. The binding source_method
    # is a condition of the query itself, so a translation, coordination or
    # consolidation can never come back, whatever the sidecar says of it: an
    # id that holds one is dropped as not_binding, as is a missing id.
    def hydrate_originals(originals)
      dropped = Hash.new(0)
      return [[], dropped] if originals.empty?

      articles_by_id = Article
                       .select(ORIGINAL_HYDRATION_SELECT)
                       .joins(CONTENTS_JOIN)
                       .joins(LEGISLATION_JOIN)
                       .where(id: originals.map { |original| original[:german_article_id] },
                              language_id: GERMAN_LANGUAGE_ID, article_type: 'ART')
                       .where('legislation.source_method IN (?)', GermanTextProvenance::BINDING_ORIGINAL_SOURCE_METHODS)
                       .index_by(&:id)

      rows = originals.filter_map do |original|
        article = articles_by_id[original[:german_article_id]]
        unless article
          dropped[:not_binding] += 1
          next
        end
        # No AUTOINCREMENT on articles: the natural key must still be the
        # one the sidecar recorded.
        unless article.content_numac == original[:german_numac] && article.article_title == original[:german_article_title]
          dropped[:key] += 1
          next
        end
        if article.try(:is_abolished) == 1
          dropped[:abolished] += 1
          next
        end

        original_row(original, article)
      end

      [rows, dropped]
    end

    # The live German row in the search_faiss shape plus :german_original.
    # A live text whose sha256 differs from the build-time hash is KEPT: the
    # live text is what the model reads and QuoteGuard verifies against;
    # only the vector is stale (text_verified false, logged 'stale').
    def original_row(original, article)
      {
        id: article.id,
        numac: article.content_numac,
        law_title: article.law_title.presence || "NUMAC #{article.content_numac}",
        article_title: article.article_title,
        article_text: article.article_text,
        article_variant: article.try(:article_variant),
        language_id: article.language_id,
        similarity: original[:similarity] * ORIGINAL_WEIGHT,
        is_abolished: false,
        is_modification: original[:is_modification],
        german_original: {
          german_article_id: article.id,
          source_method: article.legislation_source_method,
          publication_date: original[:publication_date],
          act_date: original[:act_date],
          kind: original[:original_kind],
          currency: original[:currency],
          amended_by: original[:amended_by].first(AMENDED_BY_SHOWN),
          amended_by_total: original[:amended_by].size,
          text_verified: Digest::SHA256.hexdigest(article.article_text.to_s) == original[:text_sha256],
          similarity: original[:similarity]
        }
      }
    end

    public

    # Shadow comparison for the originals this instance's last search
    # hydrated and withheld: the rows of the legislation pool that are their
    # NL or FR translation (same numac, same article number), each pair as
    # original~translation:main/German similarity. The replay takes the
    # median of the same ratio to set ORIGINAL_WEIGHT. Never raises: the
    # fan-out calls it inside the legislation job.
    def log_shadow_originals(legislation_rows)
      originals = Array(@shadow_originals)
      return if originals.empty?

      pairs = originals.flat_map do |original|
        key = original_article_key(original)
        next [] unless key

        Array(legislation_rows).filter_map do |row|
          next unless row.is_a?(Hash) && [1, 2].include?(row[:language_id]) && original_article_key(row) == key

          "#{original[:id]}~#{row[:id]}:#{row[:similarity].to_f.round(3)}/" \
            "#{original.dig(:german_original, :similarity).to_f.round(3)}"
        end
      end
      Rails.logger.info(
        "#{LOG_TAG} originals shadow: originals=#{originals.size} translation_pairs=#{pairs.size} " \
        "pairs=#{pairs.join(',')}"
      )
    rescue StandardError => e
      Rails.logger.warn("#{LOG_TAG} originals shadow log skipped: #{e.class}")
    end

    private

    # [numac, "#art-N"] of a row, nil without an article number: an NL or FR
    # row with the same key is the translation of the German original.
    def original_article_key(row)
      anchor = extract_article_anchor(row[:article_title].to_s)
      anchor && [row[:numac].to_s, anchor]
    end

    def log_summary(hits:, pointers:, above_floor:, rows:, kept:, dropped:, originals:)
      verdicts = kept.map do |row|
        evidence = row[:german_evidence]
        flags = [evidence[:currency]]
        flags << 'sha' if evidence[:wording_verified]
        flags << 'mod' if evidence[:is_modification]
        "#{row[:id]}:#{flags.join('+')}"
      end
      Rails.logger.info(
        "#{LOG_TAG} mode=#{@mode} hits=#{hits.size} pointers=#{pointers.size} " \
        "above_floor=#{above_floor.size} hydrated=#{rows.size} kept=#{kept.size} " \
        "dropped=#{dropped.map { |reason, count| "#{reason}:#{count}" }.join(',')} " \
        "similarities=#{kept.map { |row| row[:german_evidence][:similarity].round(3) }.join(',')} " \
        "verdicts=#{verdicts.join(',')} #{originals_summary(originals)}"
      )
    end

    # originals=<mode> and what became of the original hits; returned is 0
    # unless both switches are forward.
    def originals_summary(originals)
      verdicts = originals[:kept].map do |row|
        evidence = row[:german_original]
        flags = [evidence[:currency]]
        flags << 'mod' if row[:is_modification]
        flags << 'stale' unless evidence[:text_verified]
        "#{row[:id]}:#{flags.join('+')}"
      end
      "originals=#{@originals_mode} hits=#{originals[:hits]} candidates=#{originals[:candidates]} " \
        "above_floor=#{originals[:above_floor]} hydrated=#{originals[:hydrated]} kept=#{originals[:kept].size} " \
        "returned=#{returns_originals? ? originals[:kept].size : 0} " \
        "dropped=#{originals[:dropped].map { |reason, count| "#{reason}:#{count}" }.join(',')} " \
        "similarities=#{originals[:kept].map { |row| row.dig(:german_original, :similarity).round(3) }.join(',')} " \
        "verdicts=#{verdicts.join(',')}"
    end
  end
end
