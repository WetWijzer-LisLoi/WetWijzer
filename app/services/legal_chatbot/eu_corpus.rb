# frozen_string_literal: true

require 'digest'
require 'date'
require 'json'
require 'sqlite3'
require 'uri'
require 'openssl'
require 'securerandom'

module LegalChatbot
  # Immutable, independently published EU source corpus. Never opens the Belgian
  # databases, creates a missing file, or fetches text during a chatbot request.
  class EuCorpus
    APPLICATION_ID = 0x45554331
    SCHEMA_VERSION = 1
    SOURCE = 'eurlex_corpus'
    MANIFEST_LIMIT = 65_536
    VERIFIED_ARTIFACT_LIMIT = 512
    EDITION_DOCUMENT_LIMIT = 512
    BASE_ACT_ID = /\A3\d{4}[A-Z]{1,2}\d{4}\z/
    KINDS = %w[article recital paragraph final].freeze
    LANGUAGE_IDS = { 'nl' => 1, 'fr' => 2, 'de' => 3, 'en' => 4 }.freeze
    OFFICIAL_LANGUAGES = %w[bg cs da de el en es et fi fr ga hr hu it lt lv mt nl pl pt ro sk sl sv].freeze
    RECITAL_CORRECTION_COVERAGE = %w[selected_representation_no_asserted_corrigenda no_unresolved_corrections_in_selected_source
                                     verified_corrected_representation verified_unchanged_recitals].freeze
    OFFICIAL_HOSTS = %w[eur-lex.europa.eu publications.europa.eu].freeze
    IDENTITY_FIELDS = %i[eu_chunk_id document_id celex work language language_id authority source_kind document_type
                         kind unit_number heading law_title title article_title url source_url document_url article_text body_sha256
                         edition_date document_date legal_status correction_status raw_sha256
                         metadata aliases ecli historical retrieval_scope judicial_kind authentic_language unit_identity_number
                         correction_observed_at correction_verification].freeze
    # Equivalent literal evidence can have newer title/provenance observations.
    # Every selected record still passes the FULL identity seal above; this
    # narrower set is only for deduplicating unchanged official source bytes.
    TEXT_IDENTITY_FIELDS = (IDENTITY_FIELDS - %i[heading law_title title article_title legal_status metadata aliases authentic_language
                                                 correction_observed_at correction_verification]).freeze
    @verified_artifacts = {}
    @edition_verified_artifacts = {}
    @edition_inventories = {}
    @artifact_mutex = Mutex.new
    @history_secret = SecureRandom.random_bytes(32)

    class Unavailable < StandardError; end
    InvalidCorpus = Unavailable

    class << self
      attr_reader :verified_artifacts, :artifact_mutex, :edition_verified_artifacts, :edition_inventories

      def default
        new
      end

      def lookup(chunk_id, historical: false)
        default.lookup(chunk_id, historical: historical) || EuLiveCorpus.default.lookup(chunk_id, historical: historical)
      rescue Unavailable, SQLite3::Exception, JSON::ParserError
        nil
      end

      def verified_record?(source)
        default.verified_record?(source) || EuLiveCorpus.default.verified_record?(source)
      rescue Unavailable, SQLite3::Exception, JSON::ParserError
        false
      end

      def official_url?(value)
        url = URI.parse(value.to_s)
        url.is_a?(URI::HTTPS) && OFFICIAL_HOSTS.include?(url.host) &&
          url.userinfo.nil? && url.port == 443 && url.path.start_with?('/') &&
          !value.to_s.match?(/[\x00-\x20\\]/)
      rescue URI::InvalidURIError
        false
      end

      # Not a persisted token or credential. This process-local attestation
      # ensures a user-supplied 'historical' flag cannot authorize dormant text.
      def history_seal(record)
        fields = IDENTITY_FIELDS.to_h { |key| [key, record[key]] }
        OpenSSL::HMAC.hexdigest('SHA256', @history_secret, JSON.generate(fields))
      end
    end

    def initialize(root: nil, manifest_path: nil)
      @disabled_in_test = Rails.env.test? && root.nil? && manifest_path.nil? && ENV['EURLEX_CORPUS_ROOT'].blank?
      production_root = '/var/lib/wetwijzer/eu-corpus'
      @root = root || ENV['EURLEX_CORPUS_ROOT'].presence || (Rails.env.production? ? production_root : Rails.root.join('storage/eu-corpus').to_s)
      @manifest_path = manifest_path || Rails.root.join('config/eurlex/corpus_manifest.json').to_s
    end

    def configured?
      !@disabled_in_test && File.file?(@manifest_path)
    end

    def verify!
      with_database do |db, manifest|
        raise Unavailable unless db.get_first_value('PRAGMA quick_check') == 'ok'
        raise Unavailable unless db.get_first_value("SELECT value FROM corpus_metadata WHERE key = 'schema_version'") == SCHEMA_VERSION.to_s
        raise Unavailable unless db.get_first_value("SELECT value FROM corpus_metadata WHERE key = 'purpose'") == 'eurlex_corpus'

        eligible = db.get_first_value('SELECT COUNT(*) FROM chunks WHERE eligible = 1')
        raise Unavailable if manifest.key?('eligible_chunks') && !(manifest['eligible_chunks'].is_a?(Integer) && manifest['eligible_chunks'] == eligible)

        { 'chunks_by_kind' => 'SELECT kind, COUNT(*) AS count FROM chunks GROUP BY kind',
          'chunks_by_language' => 'SELECT d.language, COUNT(*) AS count FROM chunks c JOIN documents d ON d.id=c.document_id GROUP BY d.language',
          'documents_by_language' => 'SELECT language, COUNT(*) AS count FROM documents GROUP BY language' }.each do |key, sql|
          next unless manifest.key?(key)

          actual = db.execute(sql).to_h { |row| [row.values_at('kind', 'language').compact.first, row['count']] }
          raise Unavailable unless manifest[key].is_a?(Hash) && manifest[key].values.all?(Integer) && manifest[key] == actual
        end
        raise Unavailable unless db.get_first_value('SELECT COUNT(*) FROM chunks_fts') == eligible
        raise Unavailable unless db.get_first_value('SELECT COUNT(DISTINCT id) FROM chunks_fts') == eligible
        raise Unavailable unless db.get_first_value('SELECT COUNT(*) FROM chunks_fts f JOIN chunks c ON c.id = f.id JOIN documents d ON d.id = c.document_id WHERE c.eligible = 1 AND f.document_id = c.document_id AND f.title = d.title AND f.heading = c.heading AND f.body = c.body') == eligible
        raise Unavailable unless db.get_first_value('SELECT COUNT(*) FROM chunks c LEFT JOIN documents d ON d.id = c.document_id WHERE d.id IS NULL OR c.eligible NOT IN (0,1)').zero?

        # Use SQLite's row-yielding API for every content-bearing scan. An
        # eager all-chunk join duplicates document metadata thousands of times
        # (>1GB in the initial 118MB artifact) before validation even begins.
        # Keep only one raw/body row plus one parsed document object alive;
        # every row and every hash is still checked, without relaxing boot seals.
        metadata_cache = {}
        db.execute('SELECT c.document_id, c.body, c.body_sha256, c.source_url, d.raw_sha256, d.metadata_json FROM chunks c JOIN documents d ON d.id=c.document_id ORDER BY d.id, c.id') do |row|
          raise Unavailable unless row['body'].is_a?(String) && row['body'].valid_encoding? && row['body'].present? &&
                                   Digest::SHA256.hexdigest(row['body']) == row['body_sha256'] &&
                                   row['raw_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/) && self.class.official_url?(row['source_url'])

          metadata_cache.clear unless metadata_cache.key?(row['document_id'])
          metadata_cache[row['document_id']] ||= JSON.parse(row['metadata_json'].to_s)
          raise Unavailable unless metadata_cache[row['document_id']].is_a?(Hash)
        end
        metadata_cache.clear
        db.execute("#{join_sql} WHERE c.eligible = 1 ORDER BY d.id, c.id") do |row|
          metadata_cache.clear unless metadata_cache.key?(row['document_id'])
          raise Unavailable unless canonical_record(row, metadata_cache: metadata_cache)
        end
        raise Unavailable unless db.get_first_value('SELECT COUNT(*) FROM raw_sources') == db.get_first_value('SELECT COUNT(*) FROM documents')
        raise Unavailable unless db.get_first_value('SELECT COUNT(*) FROM raw_sources r JOIN documents d ON d.id=r.document_id') == db.get_first_value('SELECT COUNT(*) FROM documents')

        db.execute('SELECT r.raw_sha256, r.raw_bytes, r.raw_payload, d.raw_sha256 AS document_sha FROM raw_sources r JOIN documents d ON d.id=r.document_id') do |row|
          raise Unavailable unless row['raw_payload'].is_a?(String) && row['raw_payload'].bytesize == row['raw_bytes'] &&
                                   row['raw_sha256'] == row['document_sha'] && Digest::SHA256.hexdigest(row['raw_payload']) == row['raw_sha256']
        end

        artifact_key = edition_artifact_key(manifest)
        self.class.artifact_mutex.synchronize do
          self.class.edition_verified_artifacts.clear if self.class.edition_verified_artifacts.size >= VERIFIED_ARTIFACT_LIMIT
          self.class.edition_verified_artifacts[artifact_key] = true
        end
        { documents: db.get_first_value('SELECT COUNT(*) FROM documents'), chunks: db.get_first_value('SELECT COUNT(*) FROM chunks'),
          eligible_chunks: eligible, schema_version: SCHEMA_VERSION }
      end
    rescue SQLite3::Exception, JSON::ParserError, SystemCallError
      raise Unavailable
    end

    def available?
      with_database { |_db| true }
    rescue Unavailable, SQLite3::Exception, JSON::ParserError, SystemCallError
      false
    end

    def lookup(chunk_id, historical: false)
      return nil unless chunk_id.is_a?(String) && chunk_id.length.between?(1, 240)

      with_database do |db|
        row = db.get_first_row("#{join_sql} WHERE c.id = ?", [chunk_id])
        canonical_record(row, historical: historical)
      end
    rescue Unavailable, SQLite3::Exception, JSON::ParserError, SystemCallError
      nil
    end

    def verified_record?(source)
      return false unless source.is_a?(Hash) && value(source, :source) == SOURCE

      historical = value(source, :historical) == true
      stored = lookup(value(source, :eu_chunk_id), historical: historical)
      return false unless stored
      return false unless IDENTITY_FIELDS.all? { |key| value(source, key) == stored[key] }
      return false unless value(source, :article_number) == stored[:article_number]

      if historical
        supplied = value(source, :history_seal).to_s
        return false unless supplied.bytesize == 64 && OpenSSL.fixed_length_secure_compare(supplied, self.class.history_seal(stored))
      end

      true
    end

    # Routing-only observation of published, eligible editions BEFORE filtering
    # individual units or source languages. A newer observed edition which lacks
    # an article must not allow that article to resurface from an older edition.
    # This is not source evidence, a completeness claim, or current-law status.
    def observed_editions(celex:)
      return [] unless celex.is_a?(String) && BASE_ACT_ID.match?(celex)

      with_database do |db, manifest|
        artifact_key = edition_artifact_key(manifest)
        verified = self.class.artifact_mutex.synchronize { self.class.edition_verified_artifacts[artifact_key] }
        verify! unless verified

        inventory_key = artifact_key + [celex, Date.current.iso8601]
        cached = self.class.artifact_mutex.synchronize { self.class.edition_inventories[inventory_key] }
        return cached.deep_dup if cached

        # One eligible anchor per document suffices for edition routing; actual
        # answer units still come from candidates/lookup and their full seals.
        # Prefer an operative article, never admit a dormant historical recital.
        clauses = "d.source_kind = 'legislation' AND (d.celex = ? OR d.celex LIKE ?) AND c.eligible = 1 " \
                  'AND c.id = (SELECT c2.id FROM chunks c2 WHERE c2.document_id = d.id AND c2.eligible = 1 ' \
                  "ORDER BY CASE WHEN c2.kind = 'article' THEN 0 ELSE 1 END, c2.id LIMIT 1)"
        inventory = []
        document_count = 0
        # Stream potentially large anchor text/provenance instead of retaining
        # hundreds of duplicated document objects just for five routing fields.
        db.execute(join_sql + " WHERE #{clauses} ORDER BY d.celex DESC, d.id LIMIT ?",
                   [celex, "0#{celex[1..]}-%", EDITION_DOCUMENT_LIMIT + 1]) do |row|
          document_count += 1
          next if document_count > EDITION_DOCUMENT_LIMIT

          record = canonical_record(row)
          next unless record && record.dig(:metadata, 'parser_status') == 'parsed' && eligible_edition_identity?(record, celex)

          inventory << record.slice(:celex, :document_id, :language, :edition_date, :document_date)
        end
        # Truncation cannot establish a reliable newest observed edition.
        return [] if document_count > EDITION_DOCUMENT_LIMIT

        self.class.artifact_mutex.synchronize do
          self.class.edition_inventories.clear if self.class.edition_inventories.size >= VERIFIED_ARTIFACT_LIMIT
          self.class.edition_inventories[inventory_key] = inventory.deep_dup
        end
        inventory
      end
    rescue Unavailable, SQLite3::Exception, JSON::ParserError, SystemCallError
      []
    end

    # MATCH expression is assembled only from quoted lexical tokens by EuSearch.
    # Filter source kind before ranking; translated editions remain separate rows.
    def candidates(match:, source_kinds:, limit: 120, celex: nil, ecli: nil, unit: nil, language: 'nl', historical: false)
      kinds = Array(source_kinds).select { |kind| %w[legislation jurisprudence].include?(kind) }
      return [] if kinds.empty?

      with_database do |db|
        eligible_clause = historical ? "(c.eligible = 1 OR c.kind = 'recital')" : 'c.eligible = 1'
        clauses = ["d.source_kind IN (#{(['?'] * kinds.length).join(',')})", eligible_clause]
        bindings = kinds.dup
        if celex
          if celex.start_with?('3') && !celex.include?('(')
            clauses << '(d.celex = ? OR d.celex LIKE ?)'
            bindings.push(celex, "0#{celex[1..]}-%")
          else
            clauses << 'd.celex = ?'
            bindings << celex
          end
        end
        if ecli
          clauses << 'd.ecli = ?'
          bindings << ecli
        end
        if unit
          clauses.push('c.kind = ?', "(REPLACE(c.number,' ','') = ? OR EXISTS (SELECT 1 FROM json_each(d.metadata_json,'$.unit_number_identities') n WHERE json_extract(n.value,'$.kind') = c.kind AND json_extract(n.value,'$.number') = c.number AND json_extract(n.value,'$.body_sha256') = c.body_sha256 AND json_extract(n.value,'$.source_url') = c.source_url AND REPLACE(json_extract(n.value,'$.number_identity'),' ','') = ?))")
          bindings.push(unit.first, unit.last.delete(' '), unit.last.delete(' '))
        end
        if match.present? && !celex && !ecli
          # A judgment's dispositive holding must not disappear behind its
          # repeated quotations of the legislation. Admit it only from a work
          # with a real lexical hit; EuSearch still requires relevant literal
          # holding text before using it as evidence.
          clauses << "(c.id IN (SELECT id FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts, 0, 0, 3, 2, 1) LIMIT ?) OR (c.kind = 'final' AND d.source_kind = 'jurisprudence' AND d.id IN (SELECT document_id FROM chunks_fts WHERE chunks_fts MATCH ? LIMIT ?)))"
          bindings.push(match, [Integer(limit), 160].min, match, [Integer(limit), 160].min)
        elsif !celex && !ecli
          return []
        end
        bindings.push(language, [Integer(limit), 160].min)
        metadata_cache = {}
        db.execute(join_sql + " WHERE #{clauses.join(' AND ')} ORDER BY CASE WHEN d.language = ? THEN 0 ELSE 1 END, CASE WHEN c.kind = 'final' AND d.source_kind = 'jurisprudence' THEN 0 ELSE 1 END, d.id, c.id LIMIT ?", bindings)
          .filter_map { |row| canonical_record(row, historical: historical, metadata_cache: metadata_cache) }
      end
    rescue Unavailable, SQLite3::Exception, JSON::ParserError, SystemCallError
      []
    end

    private

    def value(source, key)
      source.key?(key) ? source[key] : source[key.to_s]
    end

    def edition_artifact_key(manifest)
      [File.expand_path(@root), manifest['sha256'], Digest::SHA256.hexdigest(JSON.generate(manifest))]
    end

    def eligible_edition_identity?(record, base)
      actual = record[:celex]
      if actual == base
        date = record[:document_date]
        return date.blank? || (date.is_a?(String) && date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(date) <= Date.current)
      end

      match = actual.to_s.match(/\A0#{Regexp.escape(base[1..])}-(\d{8})\z/)
      return false unless match

      date = Date.strptime(match[1], '%Y%m%d')
      return false if date > Date.current

      # A published date observation may be absent, but cannot contradict the
      # public consolidation identity used to decide chronological routing.
      record[:edition_date].blank? || record[:edition_date] == date.iso8601
    rescue Date::Error
      false
    end

    def artifact
      raise Unavailable if @disabled_in_test
      raise Unavailable unless File.file?(@manifest_path) && File.size(@manifest_path) <= MANIFEST_LIMIT

      manifest = JSON.parse(File.read(@manifest_path, encoding: 'UTF-8'))
      sha = manifest['sha256']
      name = manifest['artifact']
      raise Unavailable unless manifest['schema_version'] == SCHEMA_VERSION && sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/)
      raise Unavailable unless name == "eu-corpus-#{sha}.sqlite3"
      raise Unavailable unless manifest['bytes'].is_a?(Integer) && manifest['bytes'].positive?
      raise Unavailable unless %w[documents chunks].all? { |key| manifest[key].is_a?(Integer) && manifest[key].positive? }

      root = File.realpath(@root)
      # The deployment contract uses the real shared directory, not a mutable
      # release/current symlink. Reject redirected ancestors as well as a leaf.
      raise Unavailable unless root.tr('\\', '/').casecmp?(File.expand_path(@root).tr('\\', '/'))

      unresolved_path = File.join(root, name)
      raise Unavailable if File.symlink?(unresolved_path)

      path = File.realpath(unresolved_path)
      raise Unavailable unless File.file?(path) && File.dirname(path).casecmp?(root)

      stat = File.stat(path)
      raise Unavailable unless stat.size == manifest['bytes']

      identity = [path, stat.dev, stat.ino, stat.size, stat.mtime.to_f, stat.ctime.to_f, sha]
      self.class.artifact_mutex.synchronize do
        unless self.class.verified_artifacts[identity]
          raise Unavailable unless Digest::SHA256.file(path).hexdigest == sha

          self.class.verified_artifacts.clear if self.class.verified_artifacts.size >= VERIFIED_ARTIFACT_LIMIT
          self.class.verified_artifacts[identity] = true
        end
      end
      [path, manifest]
    rescue JSON::ParserError, SystemCallError
      raise Unavailable
    end

    def with_database
      path, manifest = artifact
      # SQLite's readonly flag is deliberate even with immutable=1: no database
      # creation fallback and no journal/WAL mutations under any caller.
      uri = "file:#{URI::DEFAULT_PARSER.escape(path.tr('\\', '/'), %r{[^a-zA-Z0-9\-._~:/]})}?mode=ro&immutable=1"
      db = SQLite3::Database.new(uri, readonly: true, uri: true)
      db.results_as_hash = true
      db.busy_timeout = 500
      db.execute('PRAGMA query_only = ON')
      raise Unavailable unless db.get_first_value('PRAGMA application_id') == APPLICATION_ID &&
                               db.get_first_value('PRAGMA user_version') == SCHEMA_VERSION
      raise Unavailable unless db.get_first_value('SELECT COUNT(*) FROM documents') == manifest['documents'] &&
                               db.get_first_value('SELECT COUNT(*) FROM chunks') == manifest['chunks']

      yield db, manifest
    ensure
      db&.close
    end

    def join_sql
      'SELECT c.id AS chunk_id, c.document_id, c.kind, c.number, c.heading, c.body, c.body_sha256, c.eligible, c.source_url AS chunk_url, ' \
        'd.celex, d.work, d.language, d.document_type, d.source_kind, d.title AS document_title, d.ecli, ' \
        'd.source_url AS document_url, d.document_date, d.edition_date, d.legal_status, d.correction_status, d.metadata_json, d.raw_sha256 ' \
        'FROM chunks c JOIN documents d ON d.id = c.document_id'
    end

    def canonical_record(row, historical: false, metadata_cache: nil)
      return nil unless row && KINDS.include?(row['kind']) && OFFICIAL_LANGUAGES.include?(row['language'])
      return nil unless %w[legislation jurisprudence].include?(row['source_kind'])
      return nil unless row['celex'].to_s.match?(%r{\A[012346][A-Za-z0-9()._/-]{1,127}\z})
      return nil unless self.class.official_url?(row['document_url']) && self.class.official_url?(row['chunk_url'])

      document_uri = URI.parse(row['document_url'])
      return nil unless document_uri.host == 'eur-lex.europa.eu' && document_uri.path.start_with?("/legal-content/#{row['language'].upcase}/") &&
                        URI.decode_www_form(document_uri.query.to_s) == [['uri', "CELEX:#{row['celex']}"]] && document_uri.fragment.nil?
      return nil unless row['chunk_url'].split('#', 2).first == row['document_url']
      return nil unless row['body'].is_a?(String) && row['body'].valid_encoding? && row['body'].present?
      return nil unless row['raw_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                        Digest::SHA256.hexdigest(row['body']) == row['body_sha256']
      return nil unless row['document_title'].is_a?(String) && row['document_title'].present?

      # Original-act recital corrections have not necessarily been applied in
      # this representation. Their preservation is not permission to present
      # old wording as current interpretive evidence.
      metadata = metadata_cache && metadata_cache[row['document_id']]
      metadata ||= JSON.parse(row['metadata_json'].to_s)
      return nil unless metadata.is_a?(Hash)

      metadata_cache[row['document_id']] = metadata if metadata_cache

      recital_certificate = row['kind'] == 'recital' && verified_recital_certificate(row, metadata)
      unverified_recital = row['kind'] == 'recital' && !RECITAL_CORRECTION_COVERAGE.include?(row['correction_status'].to_s.downcase) && !recital_certificate
      historical_evidence = Array(metadata['historical_recitals']).any? do |unit|
        unit.is_a?(Hash) && unit['number'].to_s == row['number'].to_s && unit['body_sha256'] == row['body_sha256'] && unit['source_url'] == row['chunk_url']
      end
      historical = historical && unverified_recital && row['celex'].start_with?('3') && metadata['parser_status'] == 'parsed' && historical_evidence
      return nil if unverified_recital && !historical
      return nil if row['eligible'] != 1 && !historical

      aliases = (Array(metadata['aliases']).select { |entry| entry.is_a?(String) && entry.present? } + identity_aliases(row)).uniq
      number_identity = Array(metadata['unit_number_identities']).find do |unit|
        unit.is_a?(Hash) && unit['kind'] == row['kind'] && unit['number'] == row['number'] &&
          unit['body_sha256'] == row['body_sha256'] && unit['source_url'] == row['chunk_url']
      end&.fetch('number_identity', nil)
      judicial_kind = case row['celex'][/\A6\d{4}([A-Z]{2})/, 1]
                      when 'CC', 'TC' then 'advocate_general_opinion'
                      when 'CJ', 'TJ', 'FJ' then 'judgment'
                      when 'CO', 'TO', 'FO' then 'order'
                      when 'CV' then 'court_opinion'
                      end
      label = unit_label(row['kind'], row['number'], row['language'], judicial_kind: judicial_kind)
      notice = if historical && row['correction_status'].to_s.match?(/unresolved/i)
                 { 'nl' => 'oorspronkelijke editie; rectificaties niet verwerkt',
                   'fr' => 'édition originale; rectifications non intégrées',
                   'de' => 'ursprüngliche Fassung; Berichtigungen nicht eingearbeitet',
                   'en' => 'original edition; corrections unresolved' }.fetch(row['language'], 'original edition; corrections unresolved')
               elsif recital_certificate
                 { 'nl' => 'oorspronkelijke editie; overweging ongewijzigd binnen geverifieerde rectificatietalen',
                   'fr' => 'édition originale; considérant inchangé selon les langues de rectification vérifiées',
                   'de' => 'ursprüngliche Fassung; Erwägungsgrund gemäß geprüften Berichtigungssprachen unverändert',
                   'en' => 'original edition; recital unchanged within verified corrigendum language scopes' }.fetch(row['language'])
               elsif historical
                 { 'nl' => 'oorspronkelijke editie; rectificaties niet geverifieerd',
                   'fr' => 'édition originale; rectifications non vérifiées',
                   'de' => 'ursprüngliche Fassung; Berichtigungen nicht geprüft',
                   'en' => 'original edition; correction coverage unknown' }.fetch(row['language'], 'original edition; correction coverage unknown')
               end
      result = {
        source: SOURCE, authority: 'EUR-Lex / Publications Office of the European Union',
        eu_chunk_id: row['chunk_id'], document_id: row['document_id'], celex: row['celex'], work: row['work'],
        language: row['language'], language_id: LANGUAGE_IDS[row['language']],
        source_kind: row['source_kind'], document_type: row['document_type'], kind: row['kind'],
        unit_number: row['number'], heading: row['heading'],
        unit_identity_number: number_identity || row['number'],
        law_title: row['document_title'], title: "#{row['document_title']} — #{label}#{" — #{notice}" if notice}",
        article_title: label, article_number: row['kind'] == 'article' ? row['number'] : nil,
        article_text: row['body'], body_sha256: row['body_sha256'], raw_sha256: row['raw_sha256'],
        url: row['chunk_url'], source_url: row['chunk_url'], document_url: row['document_url'],
        ecli: row['ecli'], edition_date: row['edition_date'], document_date: row['document_date'],
        legal_status: row['legal_status'], correction_status: recital_certificate ? 'verified_unchanged_recitals' : row['correction_status'], metadata: metadata,
        correction_observed_at: recital_certificate ? recital_certificate['observed_at'] : nil,
        correction_verification: recital_certificate ? recital_certificate['method'] : nil,
        aliases: aliases, historical: historical, judicial_kind: judicial_kind,
        authentic_language: metadata['authentic_language'],
        retrieval_scope: historical ? 'original_edition_explicit' : 'eligible_source_edition'
      }
      result[:history_seal] = self.class.history_seal(result) if historical
      result
    rescue JSON::ParserError, URI::InvalidURIError, ArgumentError
      nil
    end

    # Publisher attests a complete observed correction closure. The immutable
    # artifact seal is not replaced by this unit seal: both must hold. Never
    # admit an article or another source/language using a recital certificate.
    def verified_recital_certificate(row, metadata)
      return false unless row['celex'].to_s.match?(/\A3\d{4}[A-Z]\d{4}\z/) && row['kind'] == 'recital'

      Array(metadata.dig('parser_metadata', 'recital_correction_certificates')).find do |proof|
        next false unless proof.is_a?(Hash) && proof['schema_version'] == 1 && proof['status'] == 'verified_unchanged_recitals' &&
                          proof['method'] == 'explicit_other_language_correction_closure' && proof['number'] == row['number'] &&
                          proof['body_sha256'] == row['body_sha256'] && proof['source_url'] == row['chunk_url'] &&
                          proof['evidence_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/) && proof['observed_at'].to_s.match?(/\A\d{4}-\d\d-\d\dT/)

        expected_identity = { 'celex' => row['celex'], 'work' => row['work'], 'language' => row['language'],
                              'raw_sha256' => row['raw_sha256'], 'source_url' => row['document_url'],
                              'expression' => metadata['expression'], 'manifestation' => metadata['manifestation'], 'item' => metadata['item'] }
        next false unless proof['source_identity'] == expected_identity && expected_identity.values.all? { |value| value.is_a?(String) && value.present? }
        next false unless proof['correction_scopes'].is_a?(Array) && proof['correction_scopes'].size.between?(1, 48) && proof['correction_scopes'].all? do |scope|
          scope.is_a?(Hash) && scope['notice_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/) &&
          scope['languages'].is_a?(Array) && scope['languages'].present? &&
          scope['languages'].all? { |language| language.is_a?(String) && language == language.upcase && OFFICIAL_LANGUAGES.include?(language.downcase) } &&
          !scope['languages'].include?(row['language'].upcase)
        end

        payload = canonical_certificate_json(proof.except('proof_sha256'))
        Digest::SHA256.hexdigest(payload) == proof['proof_sha256']
      end
    end

    def canonical_certificate_json(value)
      normalized = case value
                   when Hash then value.keys.sort.to_h { |key| [key, JSON.parse(canonical_certificate_json(value[key]))] }
                   when Array then value.map { |entry| JSON.parse(canonical_certificate_json(entry)) }
                   else value
                   end
      JSON.generate(normalized)
    end

    def identity_aliases(row)
      identity = row['celex'].match(/\A[03](\d{4})([RL])(\d{4})/)
      if identity
        year, kind, number = identity.captures
        number = number.to_i.to_s
        identifiers = ["#{year}/#{number}", "#{number}/#{year}"]
        # The institutional suffix (EU/EC/EEG/...) comes only from the actual
        # title, not an assumption based on adoption year.
        identifiers.concat(row['document_title'].scan(%r{\b(?:#{year}/#{number}|#{number}/#{year})/(?:EU|EC|EEG|EG|CE|EEC|UE)\b}i))
        prefixes = kind == 'L' ? %w[Richtlijn Directive Richtlinie] : %w[Verordening Regulation Règlement Verordnung]
        identifiers + prefixes.product(identifiers).map { |prefix, id| "#{prefix} #{id}" }
      elsif (case_id = row['celex'].match(/\A6(\d{4})([CTF])[A-Z](\d{4})/))
        year, court, number = case_id.captures
        aliases = ["#{court}-#{number.to_i}/#{year[-2..]}", "#{court}-#{number.to_i}/#{year}"]
        party = { '61997CJ0162' => 'Nilsson', '62017CJ0673' => 'Planet49' }[row['celex']]
        aliases << party if party && row['document_title'].match?(/\b#{Regexp.escape(party)}\b/i)
        aliases
      else
        []
      end
    end

    def unit_label(kind, number, language, judicial_kind: nil)
      labels = {
        'article' => %w[Artikel Article Artikel Article], 'recital' => %w[Overweging Considérant Erwägungsgrund Recital],
        'paragraph' => %w[Punt Point Randnummer Paragraph], 'final' => %w[Slotbepaling Disposition Schlussbestimmung Final]
      }
      if kind == 'final' && judicial_kind
        labels['final'] = if judicial_kind == 'advocate_general_opinion'
                            %w[Conclusie Conclusions Schlussanträge Conclusion]
                          else
                            ['Dictum', 'Dispositif', 'Entscheidungsformel', 'Operative part']
                          end
      end
      "#{labels.fetch(kind).fetch(%w[nl fr de en].index(language) || 3)} #{number}".strip
    end
  end
end
