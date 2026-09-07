# frozen_string_literal: true

# FBL-011: aggregate ciphertext-state audit across every model that declares
# encrypted attributes. Counts ONLY - no plaintext, no ciphertext and no row
# identifiers ever leave this service except failure IDs (integers) that the
# caller may persist to the operator journal. The classification per value:
#
#   current             decrypts, and re-decrypts with the primary key alone
#                       (when previous-scheme keys are configured; with none
#                       configured every decryptable value is current)
#   previous_scheme     decrypts only via a configured previous key
#   plaintext_compatible not an encryption payload; readable because
#                       support_unencrypted_data is still on (legacy rows)
#   failed              an encryption payload no configured key decrypts -
#                       the class FBL-010 exists to surface before rotation
#   blank               NULL/empty
class EncryptionAuditService
  Result = Struct.new(:model, :attribute, :counts, :failed_ids, keyword_init: true)

  CLASSES = %i[current previous_scheme plaintext_compatible failed blank].freeze

  def self.encrypted_models
    Rails.application.eager_load!
    ActiveRecord::Base.descendants.select do |klass|
      !klass.abstract_class? && klass.respond_to?(:encrypted_attributes) &&
        klass.encrypted_attributes.present? && klass.table_exists?
    end.sort_by(&:name)
  rescue StandardError
    []
  end

  def self.audit(models: encrypted_models, batch_size: 500)
    models.flat_map do |klass|
      klass.encrypted_attributes.map do |attribute|
        counts = CLASSES.index_with { 0 }
        failed_ids = []
        klass.unscoped.find_each(batch_size: batch_size) do |record|
          kind = classify(record, attribute)
          counts[kind] += 1
          failed_ids << record.id if kind == :failed
        end
        Result.new(model: klass.name, attribute: attribute.to_s,
                   counts: counts, failed_ids: failed_ids.first(200))
      end
    end
  end

  def self.classify(record, attribute)
    # NOT ciphertext_for (it re-encrypts the in-memory value) and NOT the
    # model reader (support_unencrypted_data swallows FAILED decryption by
    # returning the raw payload as plaintext): read the stored bytes and
    # decrypt explicitly.
    raw = record.read_attribute_before_type_cast(attribute)
    return :blank if raw.nil? || raw == ''

    return :plaintext_compatible unless encrypted_payload?(raw)

    deterministic = deterministic?(record.class, attribute)
    keys = all_keys(deterministic)
    # Rails encrypts with the LAST key of a key array; older array entries
    # and any configured previous schemes are previous-scheme states that
    # encryption:reencrypt must drain. (The 2026-08 placeholder rotation's
    # legacy-salt provider was removed with Release B; a future rotation
    # needs an equivalent probe again - see the rotation runbook.)
    if decrypts_with?(raw, [keys.last], deterministic)
      :current
    elsif (keys.length > 1 && decrypts_with?(raw, keys[0..-2], deterministic)) ||
          decrypts_with_previous_schemes?(raw)
      :previous_scheme
    else
      :failed
    end
  end

  def self.encrypted_payload?(raw)
    ActiveRecord::Encryption.message_serializer.load(raw)
    true
  rescue StandardError
    false
  end

  def self.deterministic?(klass, attribute)
    klass.type_for_attribute(attribute).scheme.deterministic?
  rescue StandardError
    false
  end

  def self.all_keys(deterministic)
    config = ActiveRecord::Encryption.config
    Array(deterministic ? config.deterministic_key : config.primary_key)
  end

  def self.previous_keys_present?(deterministic)
    all_keys(deterministic).length > 1 ||
      ActiveRecord::Encryption.config.previous_schemes.present?
  end

  # Probes every globally configured previous scheme through its OWN key
  # provider (a scheme may pin a non-global derivation salt, which plain
  # key material can never reproduce).
  def self.decrypts_with_previous_schemes?(raw)
    ActiveRecord::Encryption.config.previous_schemes.any? do |scheme|
      ActiveRecord::Encryption.encryptor.decrypt(raw, key_provider: scheme.key_provider)
      true
    rescue StandardError
      false
    end
  end

  # deterministic? only selects WHICH key the value was written with; the
  # decrypt side always reads the IV from the message headers.
  def self.decrypts_with?(raw, keys, _deterministic)
    key_provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(keys)
    ActiveRecord::Encryption.encryptor.decrypt(raw, key_provider: key_provider)
    true
  rescue StandardError
    false
  end
end
