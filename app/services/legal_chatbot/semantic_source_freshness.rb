# frozen_string_literal: true

require 'digest'
require 'json'
require 'net/http'
require 'uri'

module LegalChatbot
  # A main-index hit is an article ID, not an immutable copy of that article.
  # Bind the loaded service to its small publication manifest, then omit IDs
  # changed/deleted after that generation's append cursor. This deliberately
  # reads neither current.json nor the multi-GB index/source corpus per query.
  # It protects freshness, not the semantic relevance of unchanged vectors.
  class SemanticSourceFreshness
    DEFAULT_PUBLICATION_ROOT = '/mnt/HC_Volume_105488593/embeddings/articles-large-main'
    GENERATION_PATTERN = /\Amain-faiss-sha256-[0-9a-f]{64}\z/
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    MANIFEST_FILENAME = 'main_faiss_manifest.json'
    MAX_JSON_BYTES = 65_536
    MAX_RESULTS = 200 # Matches the main FAISS server's response bound.
    MAX_SQLITE_INTEGER = (2**63) - 1
    HEALTH_FIELDS = %w[status ready generation manifest_schema_version index_sha256 ids_sha256
                       index_size ids_count indexed_vectors dimension embedding_model
                       embedding_dimension metric_type source_laws_generation
                       indexed_source_content_sha256].freeze
    GENERATION_FIELDS = %w[schema_version created_at artifacts index embedding source_laws append].freeze

    Result = Struct.new(:response, :failure, :rejected_count, keyword_init: true) do
      def available?
        failure.nil?
      end
    end

    class Unavailable < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.to_s)
      end
    end

    def initialize(faiss_url:, publication_root: ENV.fetch('QUALITY_MAIN_FAISS_ROOT', DEFAULT_PUBLICATION_ROOT))
      @faiss_url = faiss_url
      @publication_root = Pathname.new(publication_root)
    end

    # The block performs only the existing FAISS request and parses its JSON.
    # If provenance is unavailable it is not called; lexical/pinned retrieval
    # remains the caller's independent fallback. Errors carry only static codes.
    def with_verified_response
      before = verified_health
      manifest = loaded_manifest(before.fetch('generation'))
      verify_manifest!(manifest, before)
      response = yield
      after = verified_health
      unavailable!(:generation_changed) unless before == after
      ids = response_article_ids(response, before.fetch('indexed_vectors'))
      stale_ids = changed_article_ids(ids, manifest.fetch('append').fetch('change_cursor'))
      results = response.fetch('results').reject { |row| stale_ids.include?(row.fetch('article_id')) }
      Result.new(response: response.merge('results' => results), rejected_count: ids.length - results.length)
    rescue Unavailable => e
      Result.new(failure: e.reason, rejected_count: 0)
    rescue Net::OpenTimeout, Net::ReadTimeout
      # The search itself ran out of time (a cold or busy index), which is no
      # provenance fault: under the catch-all below the 10 s timeouts of
      # 2026-10-14 09:10 and 13:31 UTC were logged as freshness_unavailable.
      Result.new(failure: :search_timeout, rejected_count: 0)
    rescue StandardError
      # Do not log response bodies, embeddings, query text or exception messages.
      Result.new(failure: :freshness_unavailable, rejected_count: 0)
    end

    private

    def unavailable!(reason)
      raise Unavailable, reason
    end

    def verified_health
      health = fetch_health
      unavailable!(:invalid_health) unless health.is_a?(Hash)
      health = health.slice(*HEALTH_FIELDS)
      valid = health['status'] == 'ok' && health['ready'] == true &&
              generation?(health['generation']) && health['manifest_schema_version'].is_a?(Integer) &&
              health['manifest_schema_version'] == 1 &&
              sha256?(health['index_sha256']) && sha256?(health['ids_sha256']) &&
              positive_integer?(health['indexed_vectors']) &&
              %w[index_size ids_count dimension embedding_dimension].all? { |key| positive_integer?(health[key]) } &&
              health['index_size'] == health['indexed_vectors'] &&
              health['ids_count'] == health['indexed_vectors'] &&
              health['dimension'] == 3072 && health['embedding_dimension'] == 3072 &&
              health['embedding_model'] == 'text-embedding-3-large' &&
              health['metric_type'].is_a?(Integer) && [0, 1].include?(health['metric_type']) &&
              health['source_laws_generation'].is_a?(String) &&
              /\Alaws-sha256-[0-9a-f]{64}\z/.match?(health['source_laws_generation']) &&
              sha256?(health['indexed_source_content_sha256'])
      unavailable!(:invalid_health) unless valid
      health
    end

    def fetch_health
      uri = URI.parse(@faiss_url)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo &&
             [nil, '', '/'].include?(uri.path) && !uri.query && !uri.fragment
        unavailable!(:health_unavailable)
      end
      uri.path = '/health'
      body = +''
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: 1, read_timeout: 2) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          unavailable!(:health_unavailable) unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            unavailable!(:invalid_health) if body.bytesize + chunk.bytesize > MAX_JSON_BYTES
            body << chunk
          end
        end
      end
      JSON.parse(body)
    rescue Unavailable
      raise
    rescue StandardError
      unavailable!(:health_unavailable)
    end

    def loaded_manifest(generation)
      # The response can choose only a strict generation basename underneath
      # the configured root. Root aliases are allowed; child symlink escapes
      # and non-regular manifests are not.
      root = @publication_root.realpath
      generations = root.join('generations').realpath
      unavailable!(:manifest_unavailable) unless generations.parent == root
      directory = generations.join(generation).realpath
      unavailable!(:manifest_unavailable) unless directory.parent == generations && directory.basename.to_s == generation
      path = directory.join(MANIFEST_FILENAME).realpath
      unavailable!(:manifest_unavailable) unless path.parent == directory && path.basename.to_s == MANIFEST_FILENAME
      unavailable!(:manifest_unavailable) unless path.file?
      # A replaced POSIX path must not turn a request into a blocking FIFO
      # open. Windows aliases NONBLOCK to WRONLY, so retain read-only there;
      # the regular-file precheck also rejects its non-regular paths.
      flags = File::RDONLY
      flags |= File::NONBLOCK unless RUBY_PLATFORM.match?(/mswin|mingw/)
      File.open(path, flags) do |file|
        file.binmode
        before = file.stat
        unavailable!(:manifest_unavailable) unless before.file? && before.size.positive? && before.size <= MAX_JSON_BYTES
        bytes = file.read(MAX_JSON_BYTES + 1)
        after = file.stat
        unless bytes.bytesize == before.size && [before.dev, before.ino, before.size, before.mtime] ==
                                                [after.dev, after.ino, after.size, after.mtime]
          unavailable!(:manifest_unavailable)
        end
        JSON.parse(bytes)
      end
    rescue Unavailable
      raise
    rescue StandardError
      unavailable!(:manifest_unavailable)
    end

    def verify_manifest!(manifest, health)
      unavailable!(:manifest_mismatch) unless manifest.is_a?(Hash)
      payload = GENERATION_FIELDS.to_h { |key| [key, manifest[key]] }
      derived_generation = "main-faiss-sha256-#{Digest::SHA256.hexdigest(JSON.generate(canonical_json(payload)))}"
      artifacts = manifest['artifacts']
      index = manifest['index']
      embedding = manifest['embedding']
      source = manifest['source_laws']
      append = manifest['append']
      valid = manifest['schema_version'].is_a?(Integer) && manifest['schema_version'] == 1 &&
              manifest['generation'] == health['generation'] &&
              derived_generation == health['generation'] &&
              artifacts.is_a?(Hash) && index.is_a?(Hash) && embedding.is_a?(Hash) &&
              source.is_a?(Hash) && append.is_a?(Hash) &&
              artifact_matches?(artifacts['index'], 'articles_large_pq_v2.faiss', health['index_sha256']) &&
              artifact_matches?(artifacts['ids'], 'articles_large_pq_v2_ids.npy', health['ids_sha256']) &&
              positive_integer?(index['vector_count']) && positive_integer?(index['dimension']) &&
              index['vector_count'] == health['indexed_vectors'] && index['dimension'] == health['dimension'] &&
              index['metric_type'].is_a?(Integer) && index['metric_type'] == health['metric_type'] &&
              embedding['model'] == health['embedding_model'] && positive_integer?(embedding['dimension']) &&
              embedding['dimension'] == health['embedding_dimension'] &&
              sha256?(source['database_sha256']) &&
              source['generation'] == "laws-sha256-#{source['database_sha256']}" &&
              source['generation'] == health['source_laws_generation'] &&
              source['indexed_content_sha256'] == health['indexed_source_content_sha256'] &&
              positive_integer?(source['indexed_content_count']) && source['indexed_content_count'] <= index['vector_count'] &&
              source['indexed_language_ids'] == [1, 2] && nonnegative_integer?(append['change_cursor'])
      unavailable!(:manifest_mismatch) unless valid
    end

    # Matches main_faiss_generation.py's UTF-8 sorted-key compact JSON. No
    # floating fields are introduced by this client into the signed payload.
    def canonical_json(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical_json(value.fetch(key))] }
      when Array
        value.map { |item| canonical_json(item) }
      else
        value
      end
    end

    def artifact_matches?(record, filename, digest)
      record.is_a?(Hash) && record['filename'] == filename && record['sha256'] == digest &&
        positive_integer?(record['size'])
    end

    def response_article_ids(response, indexed_vectors)
      unavailable!(:invalid_response) unless response.is_a?(Hash) && response['results'].is_a?(Array) &&
                                             response['results'].length <= MAX_RESULTS &&
                                             positive_integer?(response['total_indexed']) &&
                                             response['total_indexed'] == indexed_vectors &&
                                             finite_number?(response['search_time_ms']) && response['search_time_ms'] >= 0
      response['results'].map do |row|
        unavailable!(:invalid_response) unless row.is_a?(Hash) && positive_integer?(row['article_id']) &&
                                               finite_number?(row['similarity'])
        row['article_id']
      end
    end

    def changed_article_ids(ids, cursor)
      # Query only bounded validated integers against the public laws ledger.
      # A read transaction gives MAX(seq) and the exclusions one DB snapshot.
      Article.connection_pool.with_connection do |connection|
        connection.transaction(requires_new: true) do
          maximum = connection.select_value('SELECT MAX(seq) FROM faiss_article_change_log')
          unavailable!(:ledger_unavailable) unless maximum.nil? || nonnegative_integer?(maximum)
          unavailable!(:ledger_rollback) if (maximum || 0) < cursor
          next [] if ids.empty?

          changed = connection.select_values(
            "SELECT DISTINCT article_id FROM faiss_article_change_log WHERE seq > #{cursor} " \
            "AND article_id IN (#{ids.uniq.join(',')})"
          )
          unavailable!(:ledger_unavailable) unless changed.all? { |id| positive_integer?(id) && ids.include?(id) }
          changed
        end
      end
    rescue Unavailable
      raise
    rescue StandardError
      unavailable!(:ledger_unavailable)
    end

    def generation?(value)
      value.is_a?(String) && GENERATION_PATTERN.match?(value)
    end

    def sha256?(value)
      value.is_a?(String) && SHA256_PATTERN.match?(value)
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive? && value <= MAX_SQLITE_INTEGER
    end

    def finite_number?(value)
      (value.is_a?(Integer) || value.is_a?(Float)) && value.finite?
    end

    def nonnegative_integer?(value)
      value.is_a?(Integer) && value >= 0 && value <= MAX_SQLITE_INTEGER
    end
  end
end
