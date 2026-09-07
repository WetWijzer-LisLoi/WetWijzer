# frozen_string_literal: true

# FBL-011: bounded, resumable, idempotent re-encryption. Dry-run BY DEFAULT;
# applying requires the exact operator confirmation phrase (a verified
# backup is the rollback story - rotation replaces old-scheme ciphertext).
# The journal carries model names, ids and counts ONLY. Idempotent because
# rows already :current are skipped, and resumable because each batch
# records the highest processed id per model.
class EncryptionReencryptService
  CONFIRM_PHRASE = 'I HAVE A VERIFIED BACKUP'

  Summary = Struct.new(:model, :scanned, :needing, :reencrypted, :failed_ids, keyword_init: true)

  def self.run(models: EncryptionAuditService.encrypted_models,
               apply: false, confirm: nil, batch_size: 200,
               journal_path: Rails.root.join('tmp/encryption_reencrypt_journal.json'))
    if apply && confirm != CONFIRM_PHRASE
      raise ArgumentError,
            "APPLY refused: set CONFIRM to the exact phrase #{CONFIRM_PHRASE.inspect} " \
            'only after verifying a restorable backup'
    end

    journal = load_journal(journal_path)
    summaries = models.map do |klass|
      resume_after = journal.dig(klass.name, 'last_id').to_i
      scanned = 0
      needing = 0
      reencrypted = 0
      failed_ids = []

      klass.unscoped.where(klass.arel_table[:id].gt(resume_after))
           .find_each(batch_size: batch_size) do |record|
        scanned += 1
        needs = klass.encrypted_attributes.any? do |attribute|
          %i[previous_scheme plaintext_compatible].include?(
            EncryptionAuditService.classify(record, attribute)
          )
        end
        if needs
          needing += 1
          if apply
            begin
              record.encrypt
              reencrypted += 1
            rescue StandardError
              failed_ids << record.id
            end
          end
        end
        if apply && (scanned % batch_size).zero?
          journal[klass.name] = { 'last_id' => record.id }
          persist_journal(journal_path, journal)
        end
      end
      if apply && scanned.positive?
        last = klass.unscoped.maximum(:id)
        journal[klass.name] = { 'last_id' => last } if last
        persist_journal(journal_path, journal)
      end

      Summary.new(model: klass.name, scanned: scanned, needing: needing,
                  reencrypted: reencrypted, failed_ids: failed_ids.first(200))
    end

    summaries
  end

  def self.load_journal(path)
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  rescue JSON::ParserError
    {}
  end

  def self.persist_journal(path, journal)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(journal))
  end
end
