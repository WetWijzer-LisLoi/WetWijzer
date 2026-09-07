# frozen_string_literal: true

require 'digest'
require 'json'
require 'net/http'
require 'open3'
require 'pathname'
require 'sqlite3'
require 'uri'

# Server-observed provenance for HMAC-authenticated chatbot quality captures.
# The laws DB remains stat-sealed on every response. Main and regional FAISS
# provenance are instead bound to SHA-256 manifests and exact loaded-generation
# health, so a pointer/file/service mismatch fails rather than mixing evidence.
class ChatbotQualityProvenance
  class Unavailable < StandardError; end

  RELEASE_PATTERN = /\A[0-9a-f]{40}\z/i
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/
  MAIN_GENERATION_PATTERN = /\Amain-faiss-sha256-[0-9a-f]{64}\z/
  MAIN_INDEXED_LANGUAGE_IDS = [1, 2].freeze
  LAWS_GENERATION_PATTERN = /\Alaws-sha256-[0-9a-f]{64}\z/
  MAIN_INDEX_FILENAME = 'articles_large_pq_v2.faiss'
  MAIN_IDS_FILENAME = 'articles_large_pq_v2_ids.npy'
  MAIN_MANIFEST_FILENAME = 'main_faiss_manifest.json'
  REGIONAL_GENERATION_PATTERN = /\Aregional-faiss-sha256-[0-9a-f]{64}\z/
  JURISPRUDENCE_GENERATION_PATTERN = /\Ajuris-faiss-sha256-[0-9a-f]{64}\z/
  JURISPRUDENCE_INDEX_FILENAME = 'jurisprudence.faiss'
  JURISPRUDENCE_IDS_FILENAME = 'jurisprudence_ids.npy'
  JURISPRUDENCE_IDENTITY_FIELDS = %w[index_sha256 ids_sha256 index_size ids_size
                                     vector_count stamped_at].freeze
  REGIONAL_MANIFEST_SCHEMA_VERSION = 3
  REGIONAL_MANIFEST_FILENAME = 'regional_manifest.json'
  REGIONAL_ARTIFACT_FILENAMES = {
    'index' => 'regional_pq.faiss',
    'ids' => 'regional_ids.npy',
    'metadata' => 'regional_meta.sqlite3'
  }.freeze
  REGIONAL_REQUIRED_META_FIELDS = %w[source title text url].freeze
  DEFAULT_EMBEDDINGS_ROOT = '/mnt/HC_Volume_105488593/embeddings'
  # Must byte-match the domain string articles_append_faiss.py seeds its
  # source-content digests with; the v1 is the cross-language framing contract.
  LAWS_CONTENT_DIGEST_DOMAIN = "wetwijzer-main-faiss-source-content-v1\x00".b.freeze

  class << self
    def snapshot
      embedding_runtime_state = embedding_runtime
      main_embeddings = main_embedding_generation
      laws_database = main_embeddings.delete(:laws_database)
      regional_embeddings = regional_generation
      validate_regional_lineage_against_active_sources!(
        regional_embeddings, main_embeddings, laws_database
      )
      confirmed_main = main_embedding_deployment
      confirmed_laws = validated_laws_database(confirmed_main)
      unless confirmed_main.fetch(:generation) == main_embeddings.fetch(:generation) &&
             confirmed_main.fetch(:manifest_sha256) == main_embeddings.fetch(:manifest_sha256) &&
             confirmed_main.fetch(:files) == main_embeddings.fetch(:files) &&
             confirmed_laws == laws_database
        raise Unavailable, 'main/laws generation changed during provenance observation'
      end
      validate_regional_lineage_against_active_sources!(
        regional_embeddings, confirmed_main, confirmed_laws
      )
      {
        schema_version: 1,
        release_sha: release_sha,
        laws_database: laws_database,
        main_embeddings: main_embeddings,
        regional_embeddings: regional_embeddings,
        jurisprudence: jurisprudence_generation,
        embedding_identity: embedding_runtime_state.fetch(:identity),
        semantic_reference_cache: embedding_runtime_state.fetch(:semantic_reference_cache)
      }
    end

    # Jurisprudence corpus generation: stamped into the compact DB by
    # jurisprudence_bridge.py after each successful index write (deliberately
    # a table, not a manifest file - faiss_serve exits on unknown manifest
    # files next to the index). Fail-closed like the others: the stamp must
    # re-derive from its own identity JSON, both FAISS artifacts must match
    # the stamped digests, and the serving process must report exactly the
    # stamped vector count. Double-read so a bridge run mid-observation
    # rejects the capture instead of mixing generations.
    def jurisprudence_generation(service_health: nil)
      first = jurisprudence_deployment
      health = service_health || fetch_service_health(
        ENV.fetch('QUALITY_JURISPRUDENCE_FAISS_HEALTH_URL',
                  ENV.fetch('FAISS_JURISPRUDENCE_URL', 'http://127.0.0.1:8765'))
      )
      %w[index_size ids_count].each do |key|
        unless health[key] == first.fetch(:identity).fetch('vector_count')
          raise Unavailable,
                "jurisprudence FAISS service #{key} does not match the stamped generation"
        end
      end
      confirmed = jurisprudence_deployment
      unless confirmed == first
        raise Unavailable, 'jurisprudence generation changed during provenance observation'
      end

      {
        generation: first.fetch(:generation),
        stamped_at: first.fetch(:identity).fetch('stamped_at'),
        vector_count: first.fetch(:identity).fetch('vector_count'),
        files: first.fetch(:files),
        service: { index_size: health['index_size'], ids_count: health['ids_count'] }
      }
    rescue Unavailable
      raise
    rescue StandardError => e
      raise Unavailable, "jurisprudence provenance is unavailable: #{e.class}"
    end

    def jurisprudence_deployment
      compact_path = ENV.fetch(
        'CHATBOT_JURISPRUDENCE_DB',
        File.join(DEFAULT_EMBEDDINGS_ROOT, 'jurisprudence_compact.db')
      )
      db = SQLite3::Database.new(compact_path, readonly: true)
      begin
        row = db.get_first_row(
          'SELECT generation, identity_json FROM bridge_generation WHERE id = 1'
        )
      ensure
        db.close
      end
      raise Unavailable, 'jurisprudence bridge generation is not stamped' if row.nil?

      generation, identity_json = row
      identity = JSON.parse(identity_json)
      unless identity.is_a?(Hash) && identity.keys.sort == JURISPRUDENCE_IDENTITY_FIELDS.sort
        raise Unavailable, 'jurisprudence generation identity is invalid'
      end
      expected = 'juris-faiss-sha256-' +
                 Digest::SHA256.hexdigest(JSON.generate(canonical_digest_value(identity)))
      unless generation.to_s.match?(JURISPRUDENCE_GENERATION_PATTERN) && generation == expected
        raise Unavailable, 'jurisprudence generation does not match its identity'
      end

      root = Pathname.new(ENV.fetch('JURISPRUDENCE_EMBEDDINGS_DIR',
                                    DEFAULT_EMBEDDINGS_ROOT)).expand_path
      files = {
        JURISPRUDENCE_INDEX_FILENAME => %w[index_sha256 index_size],
        JURISPRUDENCE_IDS_FILENAME => %w[ids_sha256 ids_size]
      }.map do |basename, (sha_key, size_key)|
        path = root.join(basename)
        unless path.file? && path.size == identity.fetch(size_key) &&
               verified_artifact_sha256(path, identity.fetch(sha_key),
                                        label: 'jurisprudence FAISS')
          raise Unavailable, "jurisprudence FAISS #{basename} does not match its stamp"
        end
        { basename: basename, size: identity.fetch(size_key),
          sha256: identity.fetch(sha_key) }
      end
      unless identity.fetch('vector_count') == (identity.fetch('ids_size') - 128) / 8
        raise Unavailable, 'jurisprudence stamped vector count is inconsistent'
      end

      { generation: generation, identity: identity, files: files }
    end

    def embedding_runtime(embedding_service: LegalChatbot::EmbeddingService.new, reference_sheets: nil)
      identity = embedding_service.identity
      sheets = reference_sheets || LegalChatbot::ReferenceSheets.new(embedding_service: embedding_service)
      semantic_cache = sheets.semantic_cache_state
      unless semantic_cache.fetch(:ready, false) == true
        raise Unavailable, 'semantic reference cache is not ready'
      end
      unless semantic_cache.fetch(:embedding_config_digest) == identity.fetch(:config_digest)
        raise Unavailable, 'semantic reference cache does not match the embedding identity'
      end

      { identity: identity, semantic_reference_cache: semantic_cache }
    rescue Unavailable
      raise
    rescue StandardError => e
      raise Unavailable, "embedding runtime provenance is unavailable: #{e.class}"
    end

    # Opaque, deterministic seal for HMAC-authenticated release gates. The
    # endpoint exposes only this digest and the release SHA, never snapshot
    # paths, file identities, manifests, or embedding details.
    def snapshot_sha256(validated_snapshot = snapshot)
      Digest::SHA256.hexdigest(JSON.generate(canonical_digest_value(validated_snapshot)))
    end

    def release_sha
      # The hook-written marker (and an optional process-level override) are
      # deployment authorities. The live directories also contain an old
      # clone's `.git` metadata: post-receive activates commits with
      # `git --git-dir ... --work-tree ... read-tree`, which deliberately does
      # not move that clone's HEAD. Treating it as a peer would therefore make
      # every correctly activated release look inconsistent.
      candidates = {
        'RELEASE_SHA' => ENV.fetch('RELEASE_SHA', nil),
        'REVISION' => read_optional(Rails.root.join('REVISION'))
      }.filter_map do |label, raw_value|
        value = raw_value.to_s.strip
        next if value.empty?

        raise Unavailable, "deployed release SHA from #{label} is invalid" unless value.match?(RELEASE_PATTERN)

        [label, value.downcase]
      end
      if candidates.any?
        distinct = candidates.map(&:last).uniq
        if distinct.length > 1
          labels = candidates.map(&:first).join(', ')
          raise Unavailable, "deployed release SHA sources disagree (#{labels})"
        end
        return distinct.first
      end

      # Development/test checkouts do not necessarily carry REVISION. Git is a
      # fallback only when neither deployment authority is present.
      git_value = git_release_sha.to_s.strip
      raise Unavailable, 'deployed release SHA is unavailable' if git_value.empty?
      raise Unavailable, 'deployed release SHA from git HEAD is invalid' unless git_value.match?(RELEASE_PATTERN)

      git_value.downcase
    end

    def laws_paths
      path = laws_database_path
      [['database', path], ['wal', Pathname.new("#{path}-wal")], ['journal', Pathname.new("#{path}-journal")]]
    end

    def laws_database_path
      configured = ENV.fetch('SEARCH_DB_PATH', nil).presence
      database = configured || Article.connection_db_config.database.to_s
      raise Unavailable, 'laws database path is unavailable' if database.blank? || database == ':memory:'

      path = Pathname.new(database).expand_path
      raise Unavailable, "laws database is missing: #{path}" unless path.file?

      path
    end

    def main_embedding_paths
      deployment = main_embedding_deployment
      [['index', deployment.fetch(:index_path)], ['ids', deployment.fetch(:ids_path)]]
    end

    def main_embedding_generation
      deployment = main_embedding_deployment
      service = validated_main_health(
        fetch_service_health(
          ENV.fetch('QUALITY_MAIN_FAISS_HEALTH_URL', ENV.fetch('FAISS_LARGE_URL', 'http://127.0.0.1:8767'))
        ),
        deployment.fetch(:expected_health)
      )
      laws_database = validated_laws_database(deployment)
      confirmed = main_embedding_deployment
      unless confirmed.fetch(:generation) == deployment.fetch(:generation) &&
             confirmed.fetch(:manifest_sha256) == deployment.fetch(:manifest_sha256) &&
             confirmed.fetch(:source_laws_generation) == deployment.fetch(:source_laws_generation) &&
             confirmed.fetch(:source_laws_database_sha256) == deployment.fetch(:source_laws_database_sha256)
        raise Unavailable, 'main FAISS active generation changed during provenance observation'
      end
      {
        generation: deployment.fetch(:generation),
        manifest_sha256: deployment.fetch(:manifest_sha256),
        source_laws_generation: deployment.fetch(:source_laws_generation),
        files: deployment.fetch(:files),
        service: service,
        laws_database: laws_database
      }
    end

    def main_embedding_deployment
      root = Pathname.new(
        ENV.fetch(
          'QUALITY_MAIN_FAISS_ROOT',
          Pathname.new(ENV.fetch('EMBEDDINGS_DIR', DEFAULT_EMBEDDINGS_ROOT)).join('articles-large-main').to_s
        )
      ).expand_path
      pointer_path = root.join('current.json')
      pointer = JSON.parse(File.binread(pointer_path))
      unless pointer['schema_version'] == 1 && pointer['generation'].to_s.match?(MAIN_GENERATION_PATTERN) &&
             pointer['manifest_sha256'].to_s.match?(SHA256_PATTERN)
        raise Unavailable, 'main FAISS current pointer is invalid'
      end

      generation = pointer.fetch('generation')
      generations_root = root.join('generations').expand_path
      generation_root = generations_root.join(generation).expand_path
      unless generation_root.dirname == generations_root
        raise Unavailable, 'main FAISS generation escapes its publication root'
      end
      real_generations_root = generations_root.realpath
      real_generation_root = generation_root.realpath
      unless real_generation_root.dirname == real_generations_root
        raise Unavailable, 'main FAISS generation symlink escapes its publication root'
      end
      generation_root = real_generation_root

      manifest_path = generation_root.join(MAIN_MANIFEST_FILENAME)
      manifest_sha256 = Digest::SHA256.file(manifest_path).hexdigest
      raise Unavailable, 'main FAISS pointer manifest digest mismatch' unless manifest_sha256 == pointer['manifest_sha256']

      manifest = JSON.parse(File.binread(manifest_path))
      unless manifest['schema_version'] == 1 && manifest['generation'] == generation
        raise Unavailable, 'main FAISS manifest generation is invalid'
      end
      artifacts = manifest['artifacts']
      unless artifacts.is_a?(Hash) && artifacts.keys.sort == %w[ids index]
        raise Unavailable, 'main FAISS manifest artifacts are invalid'
      end

      paths = {
        'index' => generation_root.join(MAIN_INDEX_FILENAME),
        'ids' => generation_root.join(MAIN_IDS_FILENAME)
      }
      expected_filenames = { 'index' => MAIN_INDEX_FILENAME, 'ids' => MAIN_IDS_FILENAME }
      files = paths.map do |role, path|
        record = artifacts[role]
        unless record.is_a?(Hash) && record['filename'] == expected_filenames.fetch(role) &&
               record['size'].is_a?(Integer) && record['size'].positive? &&
               record['sha256'].to_s.match?(SHA256_PATTERN) && path.file? &&
               path.size == record['size'] && verified_artifact_sha256(path, record['sha256'])
          raise Unavailable, "main FAISS #{role} does not match its manifest"
        end
        { role: role, basename: path.basename.to_s, size: record['size'], sha256: record['sha256'] }
      end

      vector_count = manifest.dig('index', 'vector_count')
      dimension = manifest.dig('embedding', 'dimension')
      embedding_model = manifest.dig('embedding', 'model')
      metric_type = manifest.dig('index', 'metric_type')
      source_laws_generation = manifest.dig('source_laws', 'generation')
      source_laws_database_sha256 = manifest.dig('source_laws', 'database_sha256')
      source_laws_database_size = manifest.dig('source_laws', 'database_size')
      indexed_content_sha256 = manifest.dig('source_laws', 'indexed_content_sha256')
      indexed_content_count = manifest.dig('source_laws', 'indexed_content_count')
      indexed_language_ids = manifest.dig('source_laws', 'indexed_language_ids')
      # The strict FAISS loader independently proves that indexed_content_count
      # equals np.unique(ids).size. It may be lower than vector_count because a
      # long source article legitimately contributes several chunk positions.
      unless vector_count.is_a?(Integer) && vector_count.positive? && dimension == 3072 &&
             embedding_model == 'text-embedding-3-large' && metric_type.is_a?(Integer) &&
             source_laws_generation.to_s.match?(LAWS_GENERATION_PATTERN) &&
             source_laws_database_sha256.to_s.match?(SHA256_PATTERN) &&
             source_laws_generation == "laws-sha256-#{source_laws_database_sha256}" &&
             source_laws_database_size.is_a?(Integer) && source_laws_database_size.positive? &&
             indexed_content_sha256.to_s.match?(SHA256_PATTERN) &&
             indexed_content_count.is_a?(Integer) && indexed_content_count.positive? &&
             indexed_content_count <= vector_count &&
             indexed_language_ids == MAIN_INDEXED_LANGUAGE_IDS
        raise Unavailable, 'main FAISS manifest runtime contract is invalid'
      end

      expected_health = {
        'status' => 'ok',
        'ready' => true,
        'generation' => generation,
        'manifest_schema_version' => 1,
        'index_sha256' => artifacts.dig('index', 'sha256'),
        'ids_sha256' => artifacts.dig('ids', 'sha256'),
        'indexed_vectors' => vector_count,
        'index_size' => vector_count,
        'ids_count' => vector_count,
        'embedding_model' => embedding_model,
        'embedding_dimension' => dimension,
        'dimension' => dimension,
        'metric_type' => metric_type,
        'source_laws_generation' => source_laws_generation,
        'indexed_source_content_sha256' => indexed_content_sha256
      }

      {
        generation: generation,
        manifest_sha256: manifest_sha256,
        source_laws_generation: source_laws_generation,
        source_laws_database_sha256: source_laws_database_sha256,
        source_laws_database_size: source_laws_database_size,
        indexed_content_sha256: indexed_content_sha256,
        indexed_content_count: indexed_content_count,
        indexed_language_ids: indexed_language_ids,
        index_path: paths.fetch('index'),
        ids_path: paths.fetch('ids'),
        files: files,
        expected_health: expected_health
      }
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Unavailable, "main FAISS generation is unavailable: #{e.class}"
    rescue JSON::ParserError
      raise Unavailable, 'main FAISS pointer/manifest is not valid JSON'
    end

    # The main-index manifest records the full-file SHA-256 of the checkpointed
    # SQLite source used to build it. Validate that digest against the actual
    # SEARCH_DB_PATH so an old index cannot attest a newer laws database.
    # Validate the live laws database by INDEXED CONTENT, not file identity.
    #
    # This used to require the live file to be byte-identical (size + sha256)
    # to what the main generation recorded, an invariant the pipeline itself
    # cannot keep: the reconciler that publishes a main generation writes its
    # own bookkeeping into laws.prod after digesting it, the ngram backfills
    # write sibling tables in the same file, and request-path writers touch it
    # too. Every such write made provenance Unavailable until the next
    # reconcile - the third appearance of this flaw on 2026-08-09, after the
    # regional builder and the reconciler's own self-invalidation. What the
    # certificate actually vouches for is that the ARTICLES the index embedded
    # are the articles the live database serves, and the manifest records
    # exactly that: indexed_content_sha256 / indexed_content_count, a framed
    # domain-separated digest over the indexed rows. Recompute it (cached by
    # file identity, so an unchanged file never rescans) and compare content.
    # Sibling-table writes no longer matter; drift in any indexed article, or
    # a missing one, still refuses certification.
    def validated_laws_database(deployment)
      path = laws_database_path
      expected_generation = deployment.fetch(:source_laws_generation)
      expected_sha256 = deployment.fetch(:source_laws_database_sha256)
      expected_content_sha256 = deployment.fetch(:indexed_content_sha256)
      expected_content_count = deployment.fetch(:indexed_content_count)
      unless expected_generation == "laws-sha256-#{expected_sha256}"
        raise Unavailable, 'main FAISS source-laws generation disagrees with its database digest'
      end

      # A hot rollback journal means the last writer died mid-transaction and
      # recovery is pending; refuse. A non-empty -wal sidecar is simply what a
      # live WAL database looks like - the content scan below reads one
      # consistent SQLite snapshot regardless, so it is no longer grounds for
      # refusal (the old byte-hashing needed quiescence; content does not).
      journal = Pathname.new("#{path}-journal")
      if journal.exist? && journal.size.positive?
        raise Unavailable, 'live laws database has a hot -journal sidecar'
      end

      verified_indexed_laws_content(
        path,
        ids_path: deployment.fetch(:ids_path),
        expected_digest: expected_content_sha256,
        expected_count: expected_content_count
      )

      {
        generation: expected_generation,
        database_sha256: expected_sha256,
        indexed_content_sha256: expected_content_sha256,
        indexed_content_count: expected_content_count,
        files: [
          {
            role: 'database', basename: path.basename.to_s,
            indexed_content_sha256: expected_content_sha256
          }
        ]
      }
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Unavailable, "laws database generation is unavailable: #{e.class}"
    end

    # Same two-tier verdict cache as verified_artifact_sha256, for the same
    # reasons (a cold Puma worker must not rescan 2.8M articles per request,
    # and a negative must be remembered for exactly the file state that
    # produced it). The key is the live file identity plus both expectations,
    # so any write to the file - even a harmless sibling-table one - misses
    # and rescans once, then caches the verdict for that exact state.
    def verified_indexed_laws_content(path, ids_path:, expected_digest:, expected_count:)
      unless expected_digest.to_s.match?(SHA256_PATTERN) &&
             expected_count.is_a?(Integer) && expected_count.positive?
        raise Unavailable, 'main FAISS indexed-content expectation is invalid'
      end

      before = path.stat
      identity = ['laws-content', path.to_s, *stable_file_identity(before), expected_digest, expected_count]
      @artifact_digest_cache_mutex ||= Mutex.new
      @artifact_digest_cache ||= {}
      memo = @artifact_digest_cache_mutex.synchronize { @artifact_digest_cache[identity] }
      unless memo.nil?
        return true if memo

        raise Unavailable, 'live laws indexed content does not match the main FAISS source generation'
      end

      persisted_key = (['quality-laws-content-v1'] + identity).join(':')
      cached = rails_cache&.read(persisted_key)
      unless cached.nil?
        @artifact_digest_cache_mutex.synchronize { @artifact_digest_cache[identity] = cached }
        return true if cached

        raise Unavailable, 'live laws indexed content does not match the main FAISS source generation'
      end

      digest, seen = indexed_laws_content_digest(path, ids_path)
      verdict = digest == expected_digest && seen == expected_count
      after = path.stat
      held_still = stable_file_identity(before) == stable_file_identity(after)
      # The SQLite snapshot makes the computation itself consistent even if a
      # writer landed mid-scan, but a verdict is only cacheable when the file
      # identity in the key still describes the state that was scanned.
      if held_still
        @artifact_digest_cache_mutex.synchronize do
          @artifact_digest_cache.clear if @artifact_digest_cache.length >= 8
          @artifact_digest_cache[identity] = verdict
        end
        rails_cache&.write(persisted_key, verdict, expires_in: 14.days)
      end
      return true if verdict

      raise Unavailable, 'live laws indexed content does not match the main FAISS source generation'
    rescue SQLite3::Exception => e
      raise Unavailable, "laws content validation failed: #{e.class}"
    end

    # Recompute the manifest's indexed-content digest from the live database.
    # The indexed id set comes from the generation's own ids artifact (the
    # reconciler's expected-ids table is TEMP and dies with its connection);
    # the artifact maps vectors to article ids and articles are chunked, so
    # ids repeat and the indexed set is the distinct ids in ascending order.
    # Framing must byte-match articles_append_faiss.py: length-framed
    # canonical JSON (sorted keys, compact, raw UTF-8), seeded with the shared
    # v1 domain - proven against a Python-generated parity vector in the tests.
    def indexed_laws_content_digest(path, ids_path)
      ids = read_npy_int64_ids(ids_path).uniq.sort
      raise Unavailable, 'main generation ids artifact is empty' if ids.empty?

      digest = Digest::SHA256.new
      digest << LAWS_CONTENT_DIGEST_DOMAIN
      seen = 0
      connection = SQLite3::Database.new(path.to_s, readonly: true)
      insert = nil
      select = nil
      begin
        connection.results_as_hash = true
        connection.execute('CREATE TEMP TABLE _provenance_expected_ids (id INTEGER PRIMARY KEY)')
        insert = connection.prepare('INSERT INTO _provenance_expected_ids VALUES (?)')
        connection.transaction do
          ids.each { |article_id| insert.execute(article_id) }
        end
        select = connection.prepare(
          'SELECT expected.id AS expected_id, ' \
          'source.id AS source_id, source.language_id, ' \
          'source.content_numac, source.article_type, ' \
          'source.article_title, source.article_text, ' \
          "COALESCE(source.updated_at, '') AS updated_at " \
          'FROM _provenance_expected_ids expected ' \
          'LEFT JOIN articles source ON source.id = expected.id ' \
          'ORDER BY expected.id'
        )
        select.execute.each do |record|
          if record['source_id'].nil?
            raise Unavailable, "live laws database is missing indexed article ID #{record['expected_id']}"
          end

          payload = JSON.generate(
            'article_text' => record['article_text'],
            'article_title' => record['article_title'],
            'article_type' => record['article_type'],
            'content_numac' => record['content_numac'],
            'id' => Integer(record['expected_id']),
            'language_id' => Integer(record['language_id']),
            'updated_at' => record['updated_at']
          )
          digest << [payload.bytesize].pack('Q>') << payload.b
          seen += 1
        end
      ensure
        # Close statements before the connection: sqlite3_close_v2 defers the
        # real close while statements are unfinalized, which leaves the file
        # handle open until GC - long enough to break same-request cache
        # keying on mtime and, on Windows, file deletion.
        insert&.close unless insert&.closed?
        select&.close unless select&.closed?
        connection.close
      end
      [digest.hexdigest, seen]
    end

    # Minimal NPY reader for the int64 ids artifact: little-endian '<i8',
    # C-order, one dimension. Anything else refuses rather than misreads.
    def read_npy_int64_ids(path)
      data = File.binread(path)
      raise Unavailable, 'ids artifact is not in NPY format' unless data.byteslice(0, 6) == "\x93NUMPY".b

      major = data.getbyte(6)
      header_length, header_start =
        case major
        when 1 then [data.byteslice(8, 2).unpack1('v'), 10]
        when 2, 3 then [data.byteslice(8, 4).unpack1('V'), 12]
        else raise Unavailable, "ids artifact NPY version #{major} is unsupported"
        end
      header = data.byteslice(header_start, header_length)
      unless header&.include?("'descr': '<i8'") && header.include?("'fortran_order': False")
        raise Unavailable, 'ids artifact is not a little-endian int64 C-order array'
      end

      data.byteslice(header_start + header_length, data.bytesize).unpack('q<*')
    end

    def regional_generation(service_health: nil)
      deployment = regional_embedding_deployment
      service = validated_regional_health(
        service_health || fetch_service_health(
          ENV.fetch('QUALITY_REGIONAL_FAISS_HEALTH_URL', ENV.fetch('FAISS_REGIONAL_URL', 'http://127.0.0.1:8770'))
        ),
        deployment.fetch(:expected_health)
      )
      confirmed = regional_embedding_deployment
      unless confirmed.fetch(:generation) == deployment.fetch(:generation) &&
             confirmed.fetch(:manifest_sha256) == deployment.fetch(:manifest_sha256) &&
             confirmed.fetch(:files) == deployment.fetch(:files) &&
             confirmed.fetch(:source_main) == deployment.fetch(:source_main) &&
             confirmed.fetch(:source_laws) == deployment.fetch(:source_laws)
        raise Unavailable, 'regional FAISS generation changed during provenance observation'
      end

      {
        generation: deployment.fetch(:generation),
        manifest_sha256: deployment.fetch(:manifest_sha256),
        files: deployment.fetch(:files),
        source_main: deployment.fetch(:source_main),
        source_laws: deployment.fetch(:source_laws),
        service: service
      }
    end

    def regional_embedding_deployment
      root = Pathname.new(ENV.fetch('REGIONAL_EMBEDDINGS_DIR', DEFAULT_EMBEDDINGS_ROOT)).expand_path
      manifest_path = Pathname.new(
        ENV.fetch('REGIONAL_FAISS_MANIFEST_PATH', root.join(REGIONAL_MANIFEST_FILENAME).to_s)
      ).expand_path
      manifest_sha256 = Digest::SHA256.file(manifest_path).hexdigest
      manifest = JSON.parse(File.binread(manifest_path))
      unless manifest['schema_version'] == REGIONAL_MANIFEST_SCHEMA_VERSION &&
             manifest['generation'].to_s.match?(REGIONAL_GENERATION_PATTERN)
        raise Unavailable, 'regional FAISS manifest identity is invalid'
      end

      expected_generation = regional_generation_identifier(manifest)
      unless manifest['generation'] == expected_generation
        raise Unavailable, 'regional FAISS generation does not match its manifest content'
      end

      artifacts = manifest['artifacts']
      unless artifacts.is_a?(Hash) && artifacts.keys.sort == REGIONAL_ARTIFACT_FILENAMES.keys.sort
        raise Unavailable, 'regional FAISS manifest artifacts are invalid'
      end

      files = REGIONAL_ARTIFACT_FILENAMES.map do |role, basename|
        record = artifacts[role]
        path = manifest_path.dirname.join(basename)
        unless record.is_a?(Hash) && record['filename'] == basename &&
               record['size'].is_a?(Integer) && record['size'].positive? &&
               record['sha256'].to_s.match?(SHA256_PATTERN) && path.file? &&
               path.size == record['size'] &&
               verified_artifact_sha256(path, record['sha256'], label: 'regional FAISS')
          raise Unavailable, "regional FAISS #{role} does not match its manifest"
        end
        { role: role, basename: basename, size: record['size'], sha256: record['sha256'] }
      end

      vector_count = manifest.dig('index', 'vector_count')
      dimension = manifest.dig('index', 'dimension')
      metric_type = manifest.dig('index', 'metric_type')
      unless vector_count.is_a?(Integer) && vector_count.positive? &&
             dimension == 3072 && [0, 1].include?(metric_type)
        raise Unavailable, 'regional FAISS manifest runtime contract is invalid'
      end
      lineage = validated_regional_source_lineage(
        manifest,
        regional_vector_count: vector_count,
        regional_dimension: dimension,
        regional_metric_type: metric_type
      )
      source_main = lineage.fetch(:source_main)
      source_laws = lineage.fetch(:source_laws)

      expected_health = {
        'status' => 'ok',
        'ready' => true,
        'generation' => manifest['generation'],
        'manifest_schema_version' => REGIONAL_MANIFEST_SCHEMA_VERSION,
        'manifest_sha256' => manifest_sha256,
        'index_sha256' => artifacts.dig('index', 'sha256'),
        'ids_sha256' => artifacts.dig('ids', 'sha256'),
        'metadata_sha256' => artifacts.dig('metadata', 'sha256'),
        'indexed_vectors' => vector_count,
        'index_size' => vector_count,
        'ids_count' => vector_count,
        'meta_entries' => vector_count,
        'dimension' => dimension,
        'metric_type' => metric_type,
        'metric' => metric_type == 1 ? 'l2->cosine' : 'inner_product',
        'meta_backend' => 'sqlite',
        'required_meta_fields' => REGIONAL_REQUIRED_META_FIELDS,
        'positional_ids_required' => true,
        'source_main_generation' => source_main.fetch(:generation),
        'source_main_manifest_sha256' => source_main.fetch(:manifest_sha256),
        'source_main_index_sha256' => source_main.fetch(:index_sha256),
        'source_main_ids_sha256' => source_main.fetch(:ids_sha256),
        'source_laws_generation' => source_laws.fetch(:generation),
        'source_laws_database_sha256' => source_laws.fetch(:database_sha256)
      }

      {
        generation: manifest['generation'],
        manifest_sha256: manifest_sha256,
        files: files,
        source_main: source_main,
        source_laws: source_laws,
        expected_health: expected_health
      }
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Unavailable, "regional FAISS generation is unavailable: #{e.class}"
    rescue JSON::ParserError
      raise Unavailable, 'regional FAISS manifest is not valid JSON'
    end

    def validated_regional_source_lineage(
      manifest,
      regional_vector_count:,
      regional_dimension:,
      regional_metric_type:
    )
      source_main = manifest['source_main']
      unless source_main.is_a?(Hash) && source_main['generation'].to_s.match?(MAIN_GENERATION_PATTERN) &&
             source_main['manifest_sha256'].to_s.match?(SHA256_PATTERN)
        raise Unavailable, 'regional FAISS source-main lineage is invalid'
      end
      source_artifacts = source_main['artifacts']
      unless source_artifacts.is_a?(Hash) && source_artifacts.keys.sort == %w[ids index]
        raise Unavailable, 'regional FAISS source-main artifacts are invalid'
      end
      expected_main_filenames = { 'index' => MAIN_INDEX_FILENAME, 'ids' => MAIN_IDS_FILENAME }
      source_records = expected_main_filenames.to_h do |role, filename|
        record = source_artifacts[role]
        unless record.is_a?(Hash) && record['filename'] == filename &&
               record['size'].is_a?(Integer) && record['size'].positive? &&
               record['sha256'].to_s.match?(SHA256_PATTERN)
          raise Unavailable, "regional FAISS source-main #{role} is invalid"
        end
        [role, record]
      end

      source_index = source_main['index']
      source_count = source_index.is_a?(Hash) ? source_index['vector_count'] : nil
      unless source_count.is_a?(Integer) && source_count >= regional_vector_count &&
             source_index['dimension'] == regional_dimension &&
             source_index['metric_type'] == regional_metric_type &&
             source_main['embedding'] == { 'model' => 'text-embedding-3-large', 'dimension' => 3072 }
        raise Unavailable, 'regional FAISS source-main runtime contract is invalid'
      end

      source_laws = manifest['source_laws']
      laws_digest = source_laws.is_a?(Hash) ? source_laws['database_sha256'].to_s : ''
      indexed_content_count = source_laws.is_a?(Hash) ? source_laws['indexed_content_count'] : nil
      unless laws_digest.match?(SHA256_PATTERN) &&
             source_laws['generation'] == "laws-sha256-#{laws_digest}" &&
             source_laws['generation'].to_s.match?(LAWS_GENERATION_PATTERN) &&
             source_laws['database_size'].is_a?(Integer) && source_laws['database_size'].positive? &&
             source_laws['indexed_content_sha256'].to_s.match?(SHA256_PATTERN) &&
             indexed_content_count.is_a?(Integer) && indexed_content_count.positive? &&
             indexed_content_count <= source_count
        raise Unavailable, 'regional FAISS source-laws lineage is invalid'
      end

      {
        source_main: {
          generation: source_main['generation'],
          manifest_sha256: source_main['manifest_sha256'],
          index_sha256: source_records.fetch('index').fetch('sha256'),
          ids_sha256: source_records.fetch('ids').fetch('sha256'),
          vector_count: source_count,
          dimension: source_index['dimension'],
          metric_type: source_index['metric_type']
        },
        source_laws: {
          generation: source_laws['generation'],
          database_sha256: laws_digest,
          database_size: source_laws['database_size'],
          indexed_content_sha256: source_laws['indexed_content_sha256'],
          indexed_content_count:
        }
      }
    end

    def validate_regional_lineage_against_active_sources!(regional, main, laws)
      source_main = regional.fetch(:source_main)
      source_laws = regional.fetch(:source_laws)
      main_files = main.fetch(:files).index_by { |record| record.fetch(:role) }
      unless source_main.fetch(:generation) == main.fetch(:generation) &&
             source_main.fetch(:manifest_sha256) == main.fetch(:manifest_sha256) &&
             source_main.fetch(:index_sha256) == main_files.fetch('index').fetch(:sha256) &&
             source_main.fetch(:ids_sha256) == main_files.fetch('ids').fetch(:sha256) &&
             source_laws.fetch(:generation) == laws.fetch(:generation) &&
             source_laws.fetch(:database_sha256) == laws.fetch(:database_sha256)
        raise Unavailable, 'regional FAISS lineage does not match the active main/laws generation'
      end
      true
    end

    def regional_generation_identifier(manifest)
      identity = manifest.reject { |key, _value| key == 'generation' }
      digest = Digest::SHA256.hexdigest(JSON.generate(canonical_digest_value(identity)))
      "regional-faiss-sha256-#{digest}"
    end

    def fingerprint_group(label, paths)
      records = paths.filter_map do |role, path|
        next unless path.exist?

        stat = path.stat
        {
          role: role,
          basename: path.basename.to_s,
          device: stat.dev,
          inode: stat.ino,
          size: stat.size,
          mtime_ns: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec
        }
      end
      raise Unavailable, "#{label} generation has no observable files" if records.empty?

      canonical = JSON.generate(records.sort_by { |record| record.fetch(:role) })
      { generation: Digest::SHA256.hexdigest(canonical), files: records }
    end

    def verified_artifact_sha256(path, expected_digest, label: 'main FAISS')
      before = path.stat
      identity = [path.to_s, *stable_file_identity(before), expected_digest]
      @artifact_digest_cache_mutex ||= Mutex.new
      @artifact_digest_cache ||= {}
      memo = @artifact_digest_cache_mutex.synchronize { @artifact_digest_cache[identity] }
      unless memo.nil?
        return true if memo

        raise Unavailable, "#{label} artifact changed or failed its digest: #{path.basename}"
      end

      # A process-only memo made every Puma restart re-hash the 57.6 GB laws
      # database on the first evidence request per worker: minutes of volume
      # reads while clients time out and queue behind it (2026-08-04, both
      # overnight capture runs lost 24/24 answers to exactly this; the July
      # captures survived only because timers - including the nightly Puma
      # restart - were paused during those eras). Rails.cache (FileStore under
      # tmp/cache) persists across restarts within a release. The key IS the
      # verification: path, device, inode, size, mtime AND the expected digest,
      # so any changed or swapped file misses and re-hashes. A deploy starts a
      # fresh release tmp and re-hashes once, which is deliberate.
      # Cache the VERDICT, not just success. Only successes used to be remembered, so while
      # the corpus disagreed with the index - which is the normal state for six days out of
      # seven, because the laws database is rebuilt daily and the FAISS index weekly - every
      # single request re-hashed 57.6 GB and then failed. That is a guaranteed timeout and a
      # full-volume read competing with live traffic, repeatable by anyone who can
      # authenticate. The key already contains inode, size, mtime and the expected digest, so
      # a negative cannot outlive the file state that produced it.
      persisted_key = (['quality-artifact-digest-v2'] + identity).join(':')
      cached = rails_cache&.read(persisted_key)
      unless cached.nil?
        @artifact_digest_cache_mutex.synchronize { @artifact_digest_cache[identity] = cached }
        return true if cached

        raise Unavailable, "#{label} artifact changed or failed its digest: #{path.basename}"
      end

      actual_digest = Digest::SHA256.file(path).hexdigest
      after = path.stat
      after_identity = [path.to_s, *stable_file_identity(after), expected_digest]
      verdict = identity == after_identity && actual_digest == expected_digest
      unless verdict
        # Remember the failure only when the file held still throughout. If it moved under us
        # the verdict describes no particular state and must not be cached.
        if identity == after_identity
          @artifact_digest_cache_mutex.synchronize do
            @artifact_digest_cache.clear if @artifact_digest_cache.length >= 8
            @artifact_digest_cache[identity] = false
          end
          rails_cache&.write(persisted_key, false, expires_in: 14.days)
        end
        raise Unavailable, "#{label} artifact changed or failed its digest: #{path.basename}"
      end

      @artifact_digest_cache_mutex.synchronize do
        @artifact_digest_cache.clear if @artifact_digest_cache.length >= 8
        @artifact_digest_cache[identity] = true
      end
      rails_cache&.write(persisted_key, true, expires_in: 14.days)
      true
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Unavailable, "#{label} artifact is unavailable: #{e.class}"
    end

    def rails_cache
      return nil unless defined?(Rails) && Rails.respond_to?(:cache)

      Rails.cache
    rescue StandardError
      nil
    end

    def validated_main_health(health, expected = nil)
      status = health['status']
      index_size = health['index_size']
      ids_count = health['ids_count']
      dimension = health['dimension']
      generation = health['generation']
      unless status == 'ok' && health['ready'] == true &&
             index_size.is_a?(Integer) && index_size.positive? &&
             health['indexed_vectors'] == index_size && ids_count == index_size &&
             dimension == 3072 && health['embedding_dimension'] == dimension &&
             health['embedding_model'] == 'text-embedding-3-large' &&
             health['manifest_schema_version'] == 1 &&
             generation.to_s.match?(MAIN_GENERATION_PATTERN) &&
             health['index_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['ids_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['metric_type'].is_a?(Integer) &&
             health['source_laws_generation'].to_s.match?(LAWS_GENERATION_PATTERN) &&
             health['indexed_source_content_sha256'].to_s.match?(SHA256_PATTERN)
        raise Unavailable, 'main FAISS health contract is invalid'
      end
      if expected && expected.any? { |field, value| health[field] != value }
        raise Unavailable, 'main FAISS health does not match its active manifest generation'
      end

      {
        status: status,
        ready: true,
        generation: generation,
        manifest_schema_version: health['manifest_schema_version'],
        index_sha256: health['index_sha256'],
        ids_sha256: health['ids_sha256'],
        indexed_vectors: health['indexed_vectors'],
        index_size: index_size,
        ids_count: ids_count,
        dimension: dimension,
        embedding_model: health['embedding_model'],
        embedding_dimension: health['embedding_dimension'],
        metric_type: health['metric_type'],
        source_laws_generation: health['source_laws_generation'],
        indexed_source_content_sha256: health['indexed_source_content_sha256'],
        metric: health['metric'],
      }
    end

    def validated_regional_health(health, expected)
      status = health['status']
      index_size = health['index_size']
      ids_count = health['ids_count']
      meta_entries = health['meta_entries']
      unless status == 'ok' && health['ready'] == true &&
             health['generation'].to_s.match?(REGIONAL_GENERATION_PATTERN) &&
             health['manifest_schema_version'] == REGIONAL_MANIFEST_SCHEMA_VERSION &&
             health['manifest_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['index_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['ids_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['metadata_sha256'].to_s.match?(SHA256_PATTERN) &&
             index_size.is_a?(Integer) && index_size.positive? &&
             health['indexed_vectors'] == index_size && ids_count == index_size &&
             meta_entries == index_size && health['dimension'] == 3072 &&
             [0, 1].include?(health['metric_type']) &&
             health['metric'] == (health['metric_type'] == 1 ? 'l2->cosine' : 'inner_product') &&
             health['meta_backend'] == 'sqlite' &&
             health['required_meta_fields'] == REGIONAL_REQUIRED_META_FIELDS &&
             health['positional_ids_required'] == true &&
             health['source_main_generation'].to_s.match?(MAIN_GENERATION_PATTERN) &&
             health['source_main_manifest_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['source_main_index_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['source_main_ids_sha256'].to_s.match?(SHA256_PATTERN) &&
             health['source_laws_generation'].to_s.match?(LAWS_GENERATION_PATTERN) &&
             health['source_laws_database_sha256'].to_s.match?(SHA256_PATTERN)
        raise Unavailable, 'regional FAISS health contract is invalid'
      end
      if expected.any? { |field, value| health[field] != value }
        raise Unavailable, 'regional FAISS health does not match its manifest generation'
      end

      {
        status: status,
        ready: true,
        generation: health['generation'],
        manifest_schema_version: health['manifest_schema_version'],
        manifest_sha256: health['manifest_sha256'],
        index_sha256: health['index_sha256'],
        ids_sha256: health['ids_sha256'],
        metadata_sha256: health['metadata_sha256'],
        indexed_vectors: health['indexed_vectors'],
        index_size: index_size,
        ids_count: ids_count,
        meta_entries: meta_entries,
        dimension: health['dimension'],
        metric_type: health['metric_type'],
        metric: health['metric'],
        meta_backend: health['meta_backend'],
        required_meta_fields: health['required_meta_fields'],
        positional_ids_required: health['positional_ids_required'],
        source_main_generation: health['source_main_generation'],
        source_main_manifest_sha256: health['source_main_manifest_sha256'],
        source_main_index_sha256: health['source_main_index_sha256'],
        source_main_ids_sha256: health['source_main_ids_sha256'],
        source_laws_generation: health['source_laws_generation'],
        source_laws_database_sha256: health['source_laws_database_sha256']
      }
    end

    def fetch_service_health(base_url)
      uri = URI.parse("#{base_url.to_s.sub(%r{/+\z}, '')}/health")
      raise Unavailable, 'FAISS health URL must use HTTP(S)' unless %w[http https].include?(uri.scheme)

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: 1,
        read_timeout: 2
      ) { |http| http.get(uri.request_uri) }
      raise Unavailable, "FAISS health returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      health = JSON.parse(response.body)
      raise Unavailable, 'FAISS health is not a JSON object' unless health.is_a?(Hash)

      health
    rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, JSON::ParserError => e
      raise Unavailable, "FAISS health is unavailable: #{e.class}"
    end

    private

    def stable_file_identity(stat)
      [
        stat.dev, stat.ino, stat.size,
        stat.mtime.to_i, stat.mtime.nsec,
        stat.ctime.to_i, stat.ctime.nsec
      ]
    end

    def canonical_digest_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), canonical|
          canonical[key.to_s] = canonical_digest_value(child)
        end.sort.to_h
      when Array
        value.map { |child| canonical_digest_value(child) }
      else
        value
      end
    end

    def read_optional(path)
      File.binread(path)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def git_release_sha
      stdout, status = Open3.capture2('git', '-C', Rails.root.to_s, 'rev-parse', 'HEAD')
      status.success? ? stdout : nil
    rescue Errno::ENOENT
      nil
    end
  end
end
