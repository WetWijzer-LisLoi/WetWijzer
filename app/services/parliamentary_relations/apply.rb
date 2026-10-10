# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'sqlite3'

module ParliamentaryRelations
  # WW-LINK-01, Stage 2: writes the reviewed relations of
  # config/parliamentary_relations.yml into the corpora. Prepared, and not to
  # be run on production before the owner has reviewed the audit
  # (rake parliamentary_relations:audit) and the plan it prints.
  #
  # For each reviewed law it plans
  #   documents.legislation_numac     the law on every document of its reviewed
  #                                   dossiers, and on no document outside them
  #                                   (the economic code's later bills and 2008
  #                                   annexes lose it);
  #   legislation.parliamentary_refs  exactly its reviewed dossiers.
  # It only counts unless apply: true. Before any write it refuses a reviewed
  # dossier whose documents carry another law's NUMAC that the relation does
  # not list in replaces_numacs, and a plan larger than max_changes unless
  # forced. The manifest may associate a dossier with several laws, but the
  # corpus has only one NUMAC per document: incompatible assignments refuse
  # this apply rather than letting the last relation overwrite the others.
  # It writes under the pipeline lock, after saving every changed
  # row's previous value to a backup file, one transaction per store, reads
  # every row back, and restores the Chamber store from the backup when the
  # laws store fails. Apply.rollback(backup) puts a backup back the same way.
  # Only the related-sources cache is invalidated.
  class Apply
    class Refused < StandardError; end

    DEFAULT_LOCK = '/mnt/HC_Volume_105488593/.wetwijzer_dl/locks/pipeline.lock'
    MAX_CHANGES = 2_000
    DOCUMENT_LANGUAGES = { 1 => 'nl', 2 => 'fr', 3 => 'fr' }.freeze

    # table 'documents' (key: id) or 'legislation' (key: [numac, language_id])
    Change = Data.define(:table, :key, :before, :after)
    Plan = Data.define(:changes, :conflicts)
    Result = Data.define(:applied, :plan, :backup_path) do
      def summary
        counts = plan.changes.group_by(&:table).transform_values(&:size)
        "parliamentary_relations:apply #{applied ? 'WRITE' : 'DRY RUN'} documents=#{counts.fetch('documents', 0)} " \
          "legislation=#{counts.fetch('legislation', 0)}#{" backup=#{backup_path}" if backup_path}"
      end
    end

    attr_reader :chamber_path, :laws_path

    def initialize(chamber_path:, laws_path:, manifest: ParliamentaryRelations.manifest, numacs: nil,
                   max_changes: MAX_CHANGES, lock_path: DEFAULT_LOCK, lock_wait: 3600, backup_dir: nil,
                   cache: Rails.cache)
      @chamber_path = chamber_path
      @laws_path = laws_path
      @manifest = manifest
      @relations = manifest.relations.select { |relation| numacs.nil? || numacs.include?(relation.numac) }
      @max_changes = max_changes
      @lock_path = lock_path
      @lock_wait = lock_wait
      @backup_dir = backup_dir || Rails.root.join('tmp', 'parliamentary_relations').to_s
      @cache = cache
    end

    def call(apply: false, force: false)
      plan = checked_plan(force)
      return Result.new(applied: false, plan: plan, backup_path: nil) unless apply

      self.class.with_pipeline_lock(@lock_path, @lock_wait) do
        plan = checked_plan(force) # the corpus may have changed while waiting
        backup = write_backup(plan.changes)
        self.class.write_changes(chamber_path, laws_path, plan.changes, :after)
        self.class.invalidate(@cache)
        Result.new(applied: true, plan: plan, backup_path: backup)
      end
    end

    def plan
      changes = []
      conflicts = []
      assignments = {}
      self.class.open_store(chamber_path, readonly: true) do |chamber|
        capture = snapshot_provenance(chamber)
        self.class.open_store(laws_path, readonly: true) do |laws|
          @relations.each { |relation| plan_relation(relation, chamber, laws, changes, conflicts, assignments, capture) }
        end
      end
      changes = changes.uniq
      changes.group_by { |change| [change.table, change.key] }.each do |(table, key), rows|
        next if rows.map(&:after).uniq.size == 1

        conflicts << "#{table} #{key.inspect}: incompatible assignments #{rows.map(&:after).uniq.inspect}"
      end
      Plan.new(changes: changes, conflicts: conflicts.uniq)
    end

    private

    def checked_plan(force)
      plan = self.plan
      raise Refused, "conflicting documents, review them first: #{plan.conflicts.join('; ')}" if plan.conflicts.any?
      raise Refused, "the plan changes #{plan.changes.size} rows, more than #{@max_changes}; FORCE=1 after review" if plan.changes.size > @max_changes && !force

      plan
    end

    def plan_relation(relation, chamber, laws, changes, conflicts, assignments, capture)
      law_rows = laws.execute('SELECT language_id, parliamentary_refs FROM legislation WHERE numac = ? ORDER BY language_id',
                              [relation.numac])
      if law_rows.empty?
        conflicts << "law #{relation.numac}: target legislation is missing"
        return
      end
      languages = law_rows.filter_map { |language_id, _refs| DOCUMENT_LANGUAGES[language_id] }.uniq
      if languages.empty?
        conflicts << "law #{relation.numac}: no supported document language"
        return
      end

      reviewed = Set.new
      incomplete = false
      relation.dossiers.each do |dossier|
        # Selecting only one NUMAC must not bypass the manifest's shared
        # dossier conflict: this legacy column cannot represent both acts.
        other_laws = @manifest.for_dossier(dossier.parliament, dossier.legislature, dossier.number)
                              .map(&:numac) - [relation.numac]
        if other_laws.any?
          conflicts << "#{dossier.parliament} #{dossier.label}: shared reviewed dossier also belongs to #{other_laws.join(', ')}; the corpus holds one NUMAC"
        end
        marks = (['?'] * dossier.number_variants.size).join(', ')
        rows = chamber.execute('SELECT id, legislation_numac, language FROM documents WHERE parliament = ? AND legislature = ? ' \
                               "AND dossier_number IN (#{marks}) ORDER BY id",
                               [dossier.parliament, dossier.legislature, *dossier.number_variants])
        missing_languages = languages - rows.map { |row| row[2] }.uniq
        if missing_languages.any?
          conflicts << "#{dossier.parliament} #{dossier.label}: incomplete reviewed dossier, missing documents in #{missing_languages.join(', ')}"
          incomplete = true
        end
        unless captured_dossier_complete?(capture, dossier, rows)
          conflicts << "#{dossier.parliament} #{dossier.label}: captured reviewed dossier rows differ from certified complete coverage"
          incomplete = true
        end
        rows.each do |id, current, _language|
          reviewed << id
          if assignments.key?(id) && assignments[id] != relation.numac
            conflicts << "document #{id}: reviewed dossiers assign both #{assignments[id]} and #{relation.numac}; the corpus holds one NUMAC"
          end
          assignments[id] ||= relation.numac
          next if current == relation.numac

          if current.present? && relation.replaces_numacs.exclude?(current)
            conflicts << "#{dossier.parliament} #{dossier.label}: document #{id} carries #{current}, not #{relation.numac}"
          else
            changes << Change.new(table: 'documents', key: id, before: current, after: relation.numac)
          end
        end
      end
      return if incomplete

      chamber.execute('SELECT id FROM documents WHERE legislation_numac = ? ORDER BY id', [relation.numac]).each do |(id)|
        changes << Change.new(table: 'documents', key: id, before: relation.numac, after: nil) unless reviewed.include?(id)
      end

      refs = relation.dossiers.map { |d| "#{d.parliament == 'senate' ? 'S' : 'K'}:#{d.label}" }.sort.to_json
      law_rows.each do |language_id, current|
        changes << Change.new(table: 'legislation', key: [relation.numac, language_id], before: current, after: refs) if current != refs
      end
    end

    def snapshot_provenance(chamber)
      return unless chamber.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'audit_snapshot_provenance'")

      rows = chamber.execute('SELECT substr(provenance, 1, 65536), length(provenance) FROM audit_snapshot_provenance LIMIT 2')
      raise Refused, 'capture must have one bounded provenance record' unless rows.one? && rows.first[1].to_i <= 65_536

      capture = JSON.parse(rows.first[0])
      unless capture.is_a?(Hash) && capture['format_version'] == 1 && capture['capture_complete'] == true && capture['ranking_complete'] == true
        raise Refused, 'captured snapshot is not certified complete'
      end

      capture
    rescue JSON::ParserError, TypeError => e
      raise Refused, "invalid capture provenance: #{e.message}"
    end

    def captured_dossier_complete?(capture, dossier, rows)
      return true unless capture

      triple = [dossier.parliament, dossier.legislature, dossier.number]
      return false unless Array(capture['reviewed_dossiers_captured']).include?(triple)

      coverage = Array(capture['dossier_document_counts']).find do |entry|
        entry.is_a?(Hash) && entry.values_at('parliament', 'legislature', 'number') == triple
      end
      actual_languages = rows.group_by { |row| row[2].to_s }.transform_values(&:size)
      coverage && coverage['complete'] == true && coverage['count'] == rows.size && coverage['by_language'] == actual_languages
    end

    def write_backup(changes)
      FileUtils.mkdir_p(@backup_dir)
      written_at = Time.now.utc
      path = File.join(@backup_dir, "parliamentary_relations.#{written_at.strftime('%Y%m%dT%H%M%SZ')}.#{SecureRandom.hex(12)}.json")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(
                     'written_at' => written_at.iso8601, 'chamber_path' => chamber_path, 'laws_path' => laws_path,
                     'relations' => @relations.map(&:numac), 'changes' => changes.map(&:to_h)
                   ))
        file.flush
        file.fsync
      end
      path
    end

    class << self
      # Puts a backup's previous values back after checking that every row
      # still holds what the apply wrote; counts only unless apply: true.
      def rollback(backup_path, apply: false, lock_path: DEFAULT_LOCK, lock_wait: 3600, cache: Rails.cache)
        backup = JSON.parse(File.read(backup_path))
        changes = backup.fetch('changes').map { |row| Change.new(**row.transform_keys(&:to_sym)) }
        check = lambda do
          drift = drifted(backup.fetch('chamber_path'), backup.fetch('laws_path'), changes)
          raise Refused, "rows changed since the apply, review them first: #{drift.first(10).join('; ')}" if drift.any?
        end
        check.call
        return changes.size unless apply

        with_pipeline_lock(lock_path, lock_wait) do
          check.call
          write_changes(backup.fetch('chamber_path'), backup.fetch('laws_path'), changes, :before)
          invalidate(cache)
          changes.size
        end
      end

      def with_pipeline_lock(lock_path, wait)
        raise Refused, "unsafe or missing pipeline lock: #{lock_path}" if !File.file?(lock_path) || File.symlink?(lock_path)

        File.open(lock_path, File::RDWR) do |lock|
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
          until lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Refused, 'timed out waiting for the pipeline lock' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.5
          end
          yield
        end
      end

      def open_store(path, readonly: false)
        raise Refused, "store not found: #{path}" unless File.file?(path)

        db = SQLite3::Database.new(path, readonly: readonly)
        db.busy_timeout = 30_000
        yield db
      ensure
        db&.close
      end

      # One transaction per store, every row read back. When the laws store
      # fails after the Chamber store committed, the Chamber store gets its
      # previous values back.
      def write_changes(chamber_path, laws_path, changes, side)
        documents, legislation = changes.partition { |change| change.table == 'documents' }
        write_store(chamber_path, documents, side)
        begin
          write_store(laws_path, legislation, side)
        rescue StandardError
          write_store(chamber_path, documents, side == :after ? :before : :after)
          raise
        end
      end

      def write_store(path, changes, side)
        return if changes.empty?

        open_store(path) do |db|
          db.transaction(:immediate) do
            changes.each do |change|
              expected = change.public_send(side == :after ? :before : :after)
              db.execute(*update(change, change.public_send(side), expected))
              raise Refused, "#{change.table} #{change.key.inspect} changed since planning or is gone" unless db.changes == 1
            end
            wrong = changes.reject { |change| current(db, change) == change.public_send(side) }
            raise Refused, "read back differs: #{wrong.first(5).map { |c| c.key.inspect }.join(', ')}" if wrong.any?
          end
        end
      end

      def update(change, value, expected)
        if change.table == 'documents'
          ['UPDATE documents SET legislation_numac = ? WHERE id = ? AND legislation_numac IS ?', [value, change.key, expected]]
        else
          ['UPDATE legislation SET parliamentary_refs = ? WHERE numac = ? AND language_id = ? AND parliamentary_refs IS ?',
           [value, *change.key, expected]]
        end
      end

      def current(db, change)
        if change.table == 'documents'
          db.get_first_value('SELECT legislation_numac FROM documents WHERE id = ?', [change.key])
        else
          db.get_first_value('SELECT parliamentary_refs FROM legislation WHERE numac = ? AND language_id = ?', change.key)
        end
      end

      def drifted(chamber_path, laws_path, changes)
        documents, legislation = changes.partition { |change| change.table == 'documents' }
        [[chamber_path, documents], [laws_path, legislation]].flat_map do |path, rows|
          next [] if rows.empty?

          open_store(path, readonly: true) do |db|
            rows.reject { |change| current(db, change) == change.after }.map { |change| "#{change.table} #{change.key.inspect}" }
          end
        end
      end

      # Only the related-sources panel shows these relations.
      def invalidate(cache)
        Linkage::JurisprudenceCacheInvalidation.new(cache: cache, prune_expired: false).call
      end
    end
  end
end
