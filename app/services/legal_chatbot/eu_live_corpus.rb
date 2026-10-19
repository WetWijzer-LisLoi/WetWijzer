# frozen_string_literal: true

require 'json'
require 'time'

module LegalChatbot
  # Published live-cache artifacts use precisely the static corpus's evidence
  # validation. The mutable index discovers immutable, content-addressed files;
  # neither its entries nor cached helper stdout are legal source authority.
  class EuLiveCorpus
    INDEX_LIMIT = 1_048_576
    MAX_ARTIFACTS = 256
    GENERIC_SHARD_LIMIT = 12
    @verified = {}
    @verification_mutex = Mutex.new
    @snapshots = {}
    @origins = {}

    class << self
      attr_reader :verified, :verification_mutex, :snapshots, :origins

      def default
        new
      end
    end

    def initialize(root: nil, reader_class: EuCorpus)
      @disabled = Rails.env.test? && root.nil? && ENV['EURLEX_LIVE_CACHE_ROOT'].blank?
      @root = root || ENV['EURLEX_LIVE_CACHE_ROOT'].presence ||
              (Rails.env.production? ? '/var/lib/wetwijzer/eu-corpus/live' : Rails.root.join('storage/eu-corpus/live').to_s)
      @reader_class = reader_class
    end

    def configured?
      !@disabled && File.file?(File.join(@root, 'cache-index.json'))
    end

    def available?
      readers = corpus_readers
      readers.any? && readers.all?(&:available?)
    rescue EuCorpus::Unavailable, JSON::ParserError, SystemCallError, ArgumentError
      false
    end

    # A valid empty/expired index is a coverage gap, not a broken backend.
    def healthy?
      corpus_readers
      true
    rescue EuCorpus::Unavailable, JSON::ParserError, SystemCallError, ArgumentError
      false
    end

    def candidates(**arguments)
      limit = Integer(arguments.fetch(:limit, 120)).clamp(1, 160)
      exact = arguments[:celex].present? || arguments[:ecli].present?
      per_shard = exact ? limit : [limit, GENERIC_SHARD_LIMIT].min
      rows = corpus_readers(criteria: arguments).flat_map do |reader|
        reader.candidates(**arguments, limit: per_shard).each do |row|
          remember_origin(row[:eu_chunk_id], reader.instance_variable_get(:@eu_live_artifact_sha))
        end
      end
      # A repeated immutable unit can appear in several source batches. If
      # their evidence identities conflict, reject that unit instead of choosing
      # whichever filesystem entry happens to come first.
      deduplicated = rows.group_by { |row| row[:eu_chunk_id] }.values.filter_map do |duplicates|
        duplicates.first if same_identity?(duplicates)
      end
      tokens = arguments[:match].to_s.scan(/"([^"]+)"/).flatten.take(12).map { |term| normalize(term) }
      deduplicated.sort_by do |row|
        literal = normalize([row[:heading], row[:article_text]].join(' '))
        hits = tokens.count { |token| literal.match?(/\b#{Regexp.escape(token)}[\p{L}\p{N}]*/u) }
        [-hits, row[:language] == arguments[:language] ? 0 : 1, row[:celex].to_s, row[:unit_number].to_s.to_i]
      end.take(limit)
    rescue EuCorpus::Unavailable, JSON::ParserError, SystemCallError, ArgumentError
      []
    end

    # Index entries only locate immutable verified artifacts. Edition routing
    # observations are read from their sealed databases, not from mutable cache
    # metadata; no language/unit filter may hide the newer observed edition.
    def observed_editions(celex:)
      return [] unless celex.is_a?(String) && EuCorpus::BASE_ACT_ID.match?(celex)

      editions = corpus_readers(criteria: { celex: celex, source_kinds: ['legislation'] }).flat_map do |reader|
        reader.observed_editions(celex: celex)
      end.uniq
      editions.length <= EuCorpus::EDITION_DOCUMENT_LIMIT ? editions : []
    rescue EuCorpus::Unavailable, JSON::ParserError, SystemCallError, ArgumentError
      []
    end

    def lookup(chunk_id, historical: false)
      return nil unless chunk_id.is_a?(String) && chunk_id.length.between?(1, 240)

      matches = corpus_readers(artifact_shas: known_origins(chunk_id)).filter_map { |reader| reader.lookup(chunk_id, historical: historical) }
      matches.first if matches.any? && same_identity?(matches)
    rescue EuCorpus::Unavailable, JSON::ParserError, SystemCallError, ArgumentError
      nil
    end

    def verified_record?(source)
      return false unless source.is_a?(Hash)

      key = source[:eu_chunk_id] || source['eu_chunk_id']
      historical = (source[:historical] || source['historical']) == true
      matches = corpus_readers(artifact_shas: known_origins(key)).filter_map do |reader|
        record = reader.lookup(key, historical: historical)
        [reader, record] if record
      end
      matches.any? && same_identity?(matches.map(&:last)) && matches.any? { |reader, _| reader.verified_record?(source) }
    rescue EuCorpus::Unavailable, JSON::ParserError, SystemCallError, ArgumentError
      false
    end

    # Maintenance requests contain only public identities. This intentionally
    # does not make any source an answer authority or certify current law.
    # The acquisition worker resolves and verifies the official text afresh.
    def refresh_requests(limit: 8)
      maximum = Integer(limit).clamp(0, 8)
      return [] if maximum.zero?

      root, index = index_and_root
      return [] unless root

      shas = []
      index['artifacts'].filter_map do |entry|
        manifest, = checked_manifest(root, entry)
        sha = manifest['sha256']
        raise EuCorpus::Unavailable if shas.include?(sha)

        shas << sha
        lifetime = manifest['live_cache']
        expires = Time.iso8601(lifetime['expires_at'])
        next if expires > Time.now.utc + 48.hours

        celex, language = lifetime.values_at('celex', 'language')
        source = celex.to_s.start_with?('6') ? 'jurisprudence' : 'legislation'
        payload = { 'operation' => 'discover', 'source_kinds' => [source], 'language' => language,
                    'depth' => 'balanced', 'terms' => [], 'celex' => celex }
        [expires, payload] if EuDiscovery.valid_payload?(payload)
      end.sort_by(&:first).take(maximum).map(&:last)
    rescue EuCorpus::Unavailable, JSON::ParserError, SystemCallError, ArgumentError
      []
    end

    private

    def same_identity?(records)
      records.map { |row| EuCorpus::TEXT_IDENTITY_FIELDS.map { |key| row[key] } }.uniq.length == 1
    end

    def normalize(text)
      text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase
    end

    def remember_origin(chunk_id, sha)
      return unless chunk_id.is_a?(String) && sha

      key = [File.expand_path(@root), chunk_id]
      self.class.verification_mutex.synchronize do
        self.class.origins.delete(self.class.origins.keys.first) if self.class.origins.size >= 4096 && !self.class.origins.key?(key)
        self.class.origins[key] ||= []
        self.class.origins[key] << sha unless self.class.origins[key].include?(sha)
      end
    end

    def known_origins(chunk_id)
      self.class.verification_mutex.synchronize { self.class.origins[[File.expand_path(@root), chunk_id]]&.dup }
    end

    def read_index(path)
      stat = File.stat(path)
      identity = [path, stat.dev, stat.ino, stat.size, stat.mtime.to_f, stat.ctime.to_f]
      self.class.verification_mutex.synchronize do
        cached = self.class.snapshots[path]
        return cached.last if cached && cached.first == identity

        index = JSON.parse(File.read(path, encoding: 'UTF-8'))
        self.class.snapshots.delete(self.class.snapshots.keys.first) if self.class.snapshots.size >= 8 && !self.class.snapshots.key?(path)
        self.class.snapshots[path] = [identity, index]
        index
      end
    end

    def manifest_in_scope?(entry, criteria)
      return true unless criteria

      lifetime = entry['live_cache']
      raise EuCorpus::Unavailable unless lifetime.is_a?(Hash)

      celex = lifetime['celex']
      raise EuCorpus::Unavailable unless celex.is_a?(String) && EuDiscovery::CELEX.match?(celex)

      kinds = Array(criteria[:source_kinds])
      source_kind = celex.start_with?('6') ? 'jurisprudence' : 'legislation'
      return false unless kinds.include?(source_kind)

      requested = criteria[:celex]
      if requested
        family = requested.start_with?('3') && !requested.include?('(') && celex.start_with?("0#{requested[1..]}-")
        return false unless celex == requested || family
      end
      # As with the pinned core, a missing translation must not hide an already
      # verified alternative. EuSearch ranks requested/authentic/English wording
      # first and preserves the actual source-language label and sealed body.
      true
    end

    def index_and_root
      return [] if @disabled
      return [] unless File.directory?(@root)

      root = File.realpath(@root)
      raise EuCorpus::Unavailable unless root.tr('\\', '/').casecmp?(File.expand_path(@root).tr('\\', '/'))

      index_path = checked_child(root, 'cache-index.json')
      raise EuCorpus::Unavailable unless File.file?(index_path) && File.size(index_path) <= INDEX_LIMIT

      index = read_index(index_path)
      unless index.is_a?(Hash) && index['schema_version'] == 1 && index['artifacts'].is_a?(Array) && index['artifacts'].length <= MAX_ARTIFACTS
        raise EuCorpus::Unavailable
      end

      [root, index]
    end

    def checked_manifest(root, entry)
      raise EuCorpus::Unavailable unless entry.is_a?(Hash) && entry['sha256'].is_a?(String) && entry['sha256'].match?(/\A[0-9a-f]{64}\z/)

      sha = entry['sha256']
      raise EuCorpus::Unavailable unless entry['artifact'] == "eu-corpus-#{sha}.sqlite3"

      manifest_path = checked_child(root, "eu-corpus-#{sha}.json")
      raise EuCorpus::Unavailable unless File.file?(manifest_path) && File.size(manifest_path) <= EuCorpus::MANIFEST_LIMIT

      manifest = JSON.parse(File.read(manifest_path, encoding: 'UTF-8'))
      raise EuCorpus::Unavailable unless manifest.is_a?(Hash) && manifest == entry
      unless manifest['schema_version'] == 1 &&
             %w[bytes documents chunks].all? { |field| manifest[field].is_a?(Integer) && manifest[field].positive? }
        raise EuCorpus::Unavailable
      end

      lifetime = manifest['live_cache']
      raise EuCorpus::Unavailable unless lifetime.is_a?(Hash) && lifetime['observed_at'].is_a?(String) && lifetime['expires_at'].is_a?(String)

      observed = Time.iso8601(lifetime['observed_at'])
      expires = Time.iso8601(lifetime['expires_at'])
      raise EuCorpus::Unavailable unless expires > observed && expires <= observed + 14.days && observed <= Time.now.utc + 60
      raise EuCorpus::Unavailable unless lifetime['current_law_certified'] == false

      [manifest, manifest_path]
    end

    def corpus_readers(criteria: nil, artifact_shas: nil)
      root, index = index_and_root
      return [] unless root

      shas = []
      entries = index['artifacts'].sort_by do |entry|
        raise EuCorpus::Unavailable unless entry.is_a?(Hash) && entry['live_cache'].is_a?(Hash)

        entry['live_cache']['observed_at'].to_s
      end.reverse
      # Origin mappings are acceleration hints, never a reason to lose a unit
      # after an atomic refresh replaces its artifact with unchanged identities.
      artifact_shas = nil if artifact_shas && !artifact_shas.intersect?(entries.filter_map { |entry| entry['sha256'] })
      entries.filter_map do |entry|
        raise EuCorpus::Unavailable unless entry.is_a?(Hash) && entry['sha256'].is_a?(String) && entry['sha256'].match?(/\A[0-9a-f]{64}\z/)

        sha = entry['sha256']
        raise EuCorpus::Unavailable if shas.include?(sha)

        shas << sha
        raise EuCorpus::Unavailable unless entry['artifact'] == "eu-corpus-#{sha}.sqlite3"
        next if artifact_shas && !artifact_shas.include?(sha)
        next unless manifest_in_scope?(entry, criteria)

        manifest, manifest_path = checked_manifest(root, entry)
        next if Time.iso8601(manifest['live_cache']['expires_at']) <= Time.now.utc

        database_path = checked_child(root, entry['artifact'])
        reader = @reader_class.new(root: root, manifest_path: manifest_path)
        raise EuCorpus::Unavailable unless reader.available?

        stat = File.stat(database_path)
        identity = [database_path, stat.dev, stat.ino, stat.size, stat.mtime.to_f, stat.ctime.to_f, sha]
        self.class.verification_mutex.synchronize do
          unless self.class.verified[identity]
            reader.verify!
            self.class.verified.delete(self.class.verified.keys.first) if self.class.verified.size >= MAX_ARTIFACTS
            self.class.verified[identity] = true
          end
        end
        reader.instance_variable_set(:@eu_live_artifact_sha, sha)
        reader
      end
    end

    def checked_child(root, name)
      raise EuCorpus::Unavailable unless name.is_a?(String) && File.basename(name) == name && !%w[. ..].include?(name)

      child = File.join(root, name)
      raise EuCorpus::Unavailable if File.symlink?(child)

      if File.exist?(child)
        path = File.realpath(child)
        raise EuCorpus::Unavailable unless File.dirname(path).casecmp?(root)
      end
      child
    end
  end
end
