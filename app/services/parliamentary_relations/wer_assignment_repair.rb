# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require 'sqlite3'

module ParliamentaryRelations
  # A one-purpose, reviewed repair for the two misassigned 53K2543 documents.
  # It intentionally does not use Apply's dossier-wide planner or writer.
  class WerAssignmentRepair
    class Refused < StandardError; end

    # This preimage is deliberately metadata-only. Content, summary and
    # timestamps are neither printed nor backed up because this repair never
    # writes them; transaction readback/tests ensure they stay untouched.
    TARGETS = {
      21_645 => { parliament: 'chamber', legislature: 53, dossier_number: '2543', document_number: '001', language: 'nl',
                  before: '2003027025', pdf_path: '/FLWB/PDF/53/2543/53K2543001.pdf' },
      21_647 => { parliament: 'chamber', legislature: 53, dossier_number: '2543', document_number: '003', language: 'nl',
                  before: '2003007131', pdf_path: '/FLWB/PDF/53/2543/53K2543003.pdf' }
    }.freeze
    PREIMAGE_COLUMNS = %w[id parliament legislature dossier_number document_number language title document_date pdf_url legislation_numac].freeze
    EXPECTED_PREIMAGE_SHA256 = '78d54c48796ba2dcd832f878d47a0c66cf1bd2c2a4b71623dc9fdb088e210ed9'
    BACKUP_VERSION = 2
    MAX_METADATA_BYTES = 65_536
    MAX_BACKUP_BYTES = (TARGETS.size * 2 * PREIMAGE_COLUMNS.size * MAX_METADATA_BYTES) + 16_384
    # sqlite3's Ruby wrapper passes C authorizer codes, without defining them.
    # https://www.sqlite.org/c3ref/c_alter_table.html
    DOCUMENT_WRITE_ACTIONS = [9, 18, 23].freeze # DELETE, INSERT, UPDATE

    Plan = Data.define(:rows, :preimage_sha256)
    Result = Data.define(:applied, :plan, :backup_path, :cache_failure)

    def initialize(chamber_path:, cache: Rails.cache, lock_wait: 0)
      @chamber_path = chamber_path
      @cache = cache
      @lock_wait = lock_wait
    end

    def plan
      with_store(readonly: true) { |db| snapshot(db) }
    end

    def call(environment = ENV)
      planned = plan
      return Result.new(applied: false, plan: planned, backup_path: nil, cache_failure: nil) unless write?(environment)

      admit!(environment, planned)
      with_locks(environment) do
        backup = nil
        with_store do |db|
          db.transaction(:immediate) do
            current = snapshot(db)
            raise Refused, 'preimage changed while waiting for lock' unless current.preimage_sha256 == planned.preimage_sha256

            protected = protected_digest(db)
            outside = outside_assignments_digest(db)
            backup = write_backup(environment.fetch('BACKUP_DIR'), current, protected)
            forbid_document_trigger_writes!(db)
            current.rows.each do |row|
              db.execute('UPDATE documents SET legislation_numac = NULL WHERE id = ? AND legislation_numac = ?',
                         [row['id'], row['legislation_numac']])
              raise Refused, "document #{row['id']} changed since preimage" unless db.changes == 1
            end
            after = snapshot(db, after: true)
            raise Refused, 'readback differs after repair' unless after.rows.all? { |row| row['legislation_numac'].nil? } &&
                                                                  same_non_numac?(current.rows, after.rows)

            verify_untouched!(db, protected, outside)
          end
        end
        cache_failure = invalidate_after_commit
        Result.new(applied: true, plan: planned, backup_path: backup, cache_failure: cache_failure)
      end
    end

    def rollback(backup_path, environment = ENV)
      backup = read_backup(backup_path)
      planned = Plan.new(backup.fetch('before'), backup.fetch('preimage_sha256'))
      return Result.new(applied: false, plan: planned, backup_path: backup_path, cache_failure: nil) unless write?(environment)

      admit!(environment, planned, rollback: true)
      with_locks(environment) do
        with_store do |db|
          db.transaction(:immediate) do
            current = snapshot(db, after: true)
            raise Refused, 'rows drifted since repair; refusing complete rollback' unless current.rows == backup.fetch('after')

            protected = protected_digest(db)
            raise Refused, 'protected target fields drifted since repair' unless secure_equal?(protected, backup.fetch('protected_sha256'))

            outside = outside_assignments_digest(db)
            forbid_document_trigger_writes!(db)
            backup.fetch('before').each do |row|
              db.execute('UPDATE documents SET legislation_numac = ? WHERE id = ? AND legislation_numac IS NULL',
                         [row['legislation_numac'], row['id']])
              raise Refused, "document #{row['id']} changed since repair" unless db.changes == 1
            end
            restored = snapshot(db)
            raise Refused, 'rollback readback differs' unless restored.rows == backup.fetch('before')

            verify_untouched!(db, protected, outside)
          end
        end
        cache_failure = invalidate_after_commit
        return Result.new(applied: true, plan: planned, backup_path: backup_path, cache_failure: cache_failure)
      end
    end

    private

    def write?(environment) = environment['APPLY'] == '1' && environment['DRY_RUN'] != '1'

    def admit!(environment, planned, rollback: false)
      keys = %w[APPLY REVIEWED PIPELINE_LOCK_PATH CHAMBER_LOCK_PATH MAX_CHANGES PREIMAGE_SHA256]
      keys << 'BACKUP_DIR' unless rollback
      keys.each do |key|
        raise Refused, "#{key} must be explicit" if environment[key].to_s.empty?
      end
      raise Refused, 'writes require APPLY=1 REVIEWED=1' unless environment['APPLY'] == '1' && environment['REVIEWED'] == '1'
      raise Refused, 'MAX_CHANGES must equal 2' unless environment['MAX_CHANGES'] == '2'
      raise Refused, 'preimage differs from the owner-reviewed snapshot' unless secure_equal?(planned.preimage_sha256, EXPECTED_PREIMAGE_SHA256)
      raise Refused, 'PREIMAGE_SHA256 does not match dry-run plan' unless secure_equal?(environment['PREIMAGE_SHA256'], planned.preimage_sha256)

      private_directory!(environment['BACKUP_DIR']) unless rollback
    end

    def snapshot(db, after: false)
      validate_schema!(db)
      rows = TARGETS.map do |id, target|
        found = db.execute("SELECT #{PREIMAGE_COLUMNS.join(', ')} FROM documents WHERE id = ? LIMIT 2", [id])
        raise Refused, "document #{id} must exist exactly once" unless found.size == 1

        hash = PREIMAGE_COLUMNS.zip(found.first).to_h
        validate_identity!(hash, target, after:)
        if hash.values.compact.any? { |value| value.to_s.bytesize > MAX_METADATA_BYTES }
          raise Refused, "document #{id} metadata is too large for a bounded preimage"
        end

        hash
      end
      Plan.new(rows.freeze, digest(rows))
    end

    def validate_schema!(db)
      actual = db.execute('PRAGMA table_info(documents)').map { |row| row[1] }
      missing = PREIMAGE_COLUMNS - actual
      raise Refused, "documents schema missing #{missing.join(', ')}" if missing.any?
    end

    def validate_identity!(row, target, after:)
      %w[parliament legislature dossier_number document_number language].each do |key|
        raise Refused, "document #{row['id']} identity drifted" unless row[key] == target[key.to_sym]
      end
      canonical_url = "https://www.dekamer.be#{target[:pdf_path]}"
      raise Refused, "document #{row['id']} PDF drifted" unless row['pdf_url'] == canonical_url

      expected = after ? nil : target[:before]
      raise Refused, "document #{row['id']} NUMAC drifted" unless row['legislation_numac'] == expected
    end

    def same_non_numac?(before, after)
      before.zip(after).all? { |left, right| left.except('legislation_numac') == right.except('legislation_numac') }
    end

    def digest(rows)
      canonical = rows.sort_by { |row| row.fetch('id') }.map { |row| row.sort.to_h }
      Digest::SHA256.hexdigest(JSON.generate(canonical, ascii_only: false))
    end

    # Hash every target column except the one we explicitly change. Large
    # public document bodies remain transient: only their digest enters the
    # private rollback record. Outside assignments are streamed, not bodies.
    def protected_digest(db)
      columns = db.execute('PRAGMA table_info(documents)').map { |row| row[1] } - ['legislation_numac']
      projection = columns.map { |column| %("#{column.gsub('"', '""')}") }.join(', ')
      result = Digest::SHA256.new
      db.execute("SELECT #{projection} FROM documents WHERE id IN (21645, 21647) ORDER BY id") do |row|
        result.update(Marshal.dump(row))
      end
      result.hexdigest
    end

    def outside_assignments_digest(db)
      result = Digest::SHA256.new
      db.execute('SELECT id, legislation_numac FROM documents WHERE id NOT IN (21645, 21647) ORDER BY id') do |row|
        result.update(Marshal.dump(row))
      end
      result.hexdigest
    end

    def verify_untouched!(db, protected, outside)
      raise Refused, 'protected target fields changed; transaction rolled back' unless secure_equal?(protected_digest(db), protected)
      raise Refused, 'outside assignments changed; transaction rolled back' unless secure_equal?(outside_assignments_digest(db), outside)
    end

    # Production's FTS maintenance triggers may write the FTS tables. No
    # trigger may write a document row (including an unrelated row/column).
    # This protects outside bodies without scanning the multi-GB corpus.
    def forbid_document_trigger_writes!(db)
      db.authorizer do |action, table, _column, _database, trigger|
        document_write = DOCUMENT_WRITE_ACTIONS.include?(action) && table == 'documents'
        document_write && trigger ? 1 : 0 # SQLITE_DENY / SQLITE_OK
      end
    end

    def write_backup(dir, plan, protected)
      private_directory!(dir)
      after = plan.rows.map { |row| row.merge('legislation_numac' => nil) }
      payload = { 'version' => BACKUP_VERSION, 'chamber_path' => @chamber_path, 'before' => plan.rows,
                  'after' => after, 'preimage_sha256' => plan.preimage_sha256, 'protected_sha256' => protected }
      payload['backup_sha256'] = Digest::SHA256.hexdigest(JSON.generate(payload))
      path = File.join(dir, "wer_assignment_repair.#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.#{SecureRandom.hex(8)}.json")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(payload))
        file.flush
        file.fsync
      end
      path
    end

    def read_backup(path)
      raise Refused, 'backup is not a regular file' unless File.file?(path) && !File.symlink?(path)

      private_backup!(path)
      raise Refused, 'backup exceeds bounded repair format' if File.size(path) > MAX_BACKUP_BYTES

      backup = JSON.parse(File.binread(path))
      raise Refused, 'backup schema mismatch' unless backup.is_a?(Hash)

      required = %w[version chamber_path before after preimage_sha256 protected_sha256 backup_sha256]
      raise Refused, 'backup schema mismatch' unless backup.keys.sort == required.sort

      checksum = backup.fetch('backup_sha256')
      unsigned = backup.except('backup_sha256')
      raise Refused, 'backup digest mismatch' unless secure_equal?(checksum.to_s, Digest::SHA256.hexdigest(JSON.generate(unsigned)))
      raise Refused, 'backup version mismatch' unless backup['version'] == BACKUP_VERSION && backup['chamber_path'] == @chamber_path
      raise Refused, 'backup protected digest invalid' unless backup['protected_sha256'].is_a?(String) && backup['protected_sha256'].match?(/\A[0-9a-f]{64}\z/)

      before = backup['before']
      after = backup['after']
      raise Refused, 'backup targets mismatch' unless before.is_a?(Array) && after.is_a?(Array) &&
                                                      before.size == TARGETS.size && after.size == TARGETS.size &&
                                                      before.all?(Hash) && after.all?(Hash) &&
                                                      before.map { |row| row['id'] } == TARGETS.keys && after.map { |row| row['id'] } == TARGETS.keys
      raise Refused, 'backup preimage digest mismatch' unless secure_equal?(backup['preimage_sha256'].to_s, digest(before))

      before.zip(after).each do |before_row, after_row|
        raise Refused, 'backup row schema mismatch' unless before_row.keys.sort == PREIMAGE_COLUMNS.sort && after_row.keys.sort == PREIMAGE_COLUMNS.sort &&
                                                           [before_row, after_row].all? { |row| row.values.compact.all? { |value| value.to_s.bytesize <= MAX_METADATA_BYTES } }

        target = TARGETS.fetch(before_row['id'])
        validate_identity!(before_row, target, after: false)
        validate_identity!(after_row, target, after: true)
        raise Refused, 'backup metadata mismatch' unless before_row.except('legislation_numac') == after_row.except('legislation_numac')
      end
      backup
    rescue JSON::ParserError, KeyError, TypeError, SystemCallError => e
      raise Refused, "invalid backup: #{e.message}"
    end

    def private_directory!(path)
      raise Refused, 'BACKUP_DIR must be an existing non-link directory' unless File.directory?(path) && !File.symlink?(path)
      raise Refused, 'BACKUP_DIR must use its resolved absolute path' unless File.realpath(path) == File.expand_path(path)
      raise Refused, 'BACKUP_DIR must be owned by the current user' unless File.stat(path).uid == Process.uid
      raise Refused, 'BACKUP_DIR must be private' unless File.stat(path).mode.nobits?(0o077)
    end

    def private_backup!(path)
      private_directory!(File.dirname(path))
      raise Refused, 'backup must be private and owned by the current user' unless File.stat(path).uid == Process.uid &&
                                                                                   (File.stat(path).mode & 0o777) == 0o600
    end

    def with_store(readonly: false)
      raise Refused, "store not found: #{@chamber_path}" unless File.file?(@chamber_path)

      db = SQLite3::Database.new(@chamber_path, readonly: readonly, readwrite: !readonly)
      db.busy_timeout = 30_000
      db.execute('PRAGMA query_only = ON') if readonly
      yield db
    ensure
      db&.close
    end

    # The global pipeline lock and update_kamer's separate Chamber lock cover
    # different writers. Take both in a fixed order; SQLite BEGIN IMMEDIATE is
    # still the final guard around the exact in-transaction preimage.
    def with_locks(environment, &)
      Apply.with_pipeline_lock(environment.fetch('PIPELINE_LOCK_PATH'), @lock_wait) do
        Apply.with_pipeline_lock(environment.fetch('CHAMBER_LOCK_PATH'), @lock_wait, &)
      end
    end

    def invalidate_after_commit
      Linkage::JurisprudenceCacheInvalidation.new(cache: @cache, prune_expired: false).call
      nil
    rescue StandardError => e
      "post-commit related-sources cache invalidation failed: #{e.class}: #{e.message}"
    end

    def secure_equal?(left, right)
      ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s) if left.to_s.bytesize == right.to_s.bytesize
    end
  end
end
