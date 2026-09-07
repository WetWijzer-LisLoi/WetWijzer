# frozen_string_literal: true

require 'digest'

# Canonical evidence contract shared by the live chatbot and the standalone
# capture/judge tools. A refusal caused by an empty or unsupported corpus is a
# measurable product outcome, not a transport failure, even though no answer
# model was invoked.
module ChatbotQualityEvidence
  SCHEMA_VERSION = 2
  SOURCE_COUNT_KEYS = %w[legislation jurisprudence parliamentary fisconet regional].freeze
  RETRIEVAL_SEARCH_KEYS = SOURCE_COUNT_KEYS
  RETRIEVAL_SEARCH_FIELDS = %w[status duration_ms timeout error].freeze
  RETRIEVAL_SEARCH_STATUSES = %w[completed error timeout saturated not_requested not_applicable].freeze
  GENERATED_RETRIEVAL_STATUS = 'results'
  # 'authoritative_source_unavailable' was always passed by the GDPR-processor
  # refusal (prompts.rb) but missing here, so that path raised ArgumentError
  # and the orchestrator's generic rescue turned it into an evidence-less 200.
  SKIPPED_RETRIEVAL_STATUSES =
    %w[no_results unsupported_corpus authoritative_source_unavailable].freeze
  GENERATION_STATUSES = %w[generated skipped].freeze
  EVIDENCE_KEYS = %w[
    schema_version retrieval_status generation_status context context_sha256
    provider_model source_counts retrieval_searches
  ].freeze

  module_function

  def generated(context:, provider_model:, source_counts:, retrieval_searches: nil)
    canonical_counts = canonical_source_counts(source_counts)
    {
      schema_version: SCHEMA_VERSION,
      retrieval_status: GENERATED_RETRIEVAL_STATUS,
      generation_status: 'generated',
      context: context.to_s,
      context_sha256: Digest::SHA256.hexdigest(context.to_s),
      provider_model: provider_model,
      source_counts: canonical_counts.transform_keys(&:to_sym),
      retrieval_searches: canonical_retrieval_searches(retrieval_searches)
    }
  end

  def skipped(retrieval_status: 'no_results', retrieval_searches: nil)
    unless SKIPPED_RETRIEVAL_STATUSES.include?(retrieval_status)
      raise ArgumentError, "unsupported skipped retrieval status: #{retrieval_status}"
    end

    {
      schema_version: SCHEMA_VERSION,
      retrieval_status: retrieval_status,
      generation_status: 'skipped',
      context: '',
      context_sha256: Digest::SHA256.hexdigest(''),
      provider_model: nil,
      source_counts: SOURCE_COUNT_KEYS.to_h { |key| [key.to_sym, 0] },
      retrieval_searches: canonical_retrieval_searches(retrieval_searches)
    }
  end

  def empty_retrieval_searches
    RETRIEVAL_SEARCH_KEYS.to_h do |key|
      [key.to_sym, { status: 'not_requested', duration_ms: 0, timeout: false, error: nil }]
    end
  end

  # Returns stable machine-readable errors used by both capture and judging.
  # Captured JSON has string keys, but accepting symbol keys keeps this helper
  # useful in focused server-side tests before Rails serializes the response.
  def validation_errors(evidence, expected_provider_model:)
    return ['quality_evidence_missing'] unless evidence.is_a?(Hash)
    return ['quality_evidence_schema_mismatch'] unless value(evidence, 'schema_version') == SCHEMA_VERSION

    evidence_keys = evidence.keys.map(&:to_s)
    retrieval_status = value(evidence, 'retrieval_status')
    generation_status = value(evidence, 'generation_status')
    context = value(evidence, 'context')
    provider_model = value(evidence, 'provider_model')
    source_counts = value(evidence, 'source_counts')
    retrieval_searches = value(evidence, 'retrieval_searches')
    errors = []
    errors << 'quality_evidence_fields_mismatch' unless evidence_keys.sort == EVIDENCE_KEYS.sort

    allowed_retrieval = [GENERATED_RETRIEVAL_STATUS, *SKIPPED_RETRIEVAL_STATUSES]
    errors << 'quality_evidence_retrieval_status_invalid' unless allowed_retrieval.include?(retrieval_status)
    errors << 'quality_evidence_generation_status_invalid' unless GENERATION_STATUSES.include?(generation_status)

    unless context.is_a?(String)
      errors << 'quality_evidence_context_missing'
    else
      expected_digest = Digest::SHA256.hexdigest(context)
      errors << 'quality_evidence_digest_mismatch' unless value(evidence, 'context_sha256') == expected_digest
    end

    canonical_counts = validated_source_counts(source_counts, errors)
    canonical_searches = validated_retrieval_searches(retrieval_searches, errors)
    if canonical_counts && canonical_searches
      SOURCE_COUNT_KEYS.each do |key|
        next unless canonical_counts.fetch(key).positive?
        next if canonical_searches.dig(key, 'status') == 'completed'

        errors << 'quality_evidence_source_count_search_status_mismatch'
      end
    end
    case generation_status
    when 'generated'
      errors << 'quality_evidence_retrieval_status_generation_mismatch' unless retrieval_status == GENERATED_RETRIEVAL_STATUS
      errors << 'quality_evidence_context_missing' if context.is_a?(String) && context.strip.empty?
      if provider_model.to_s.strip.empty?
        errors << 'quality_evidence_provider_model_missing'
      elsif provider_model != expected_provider_model
        errors << 'quality_evidence_provider_model_mismatch'
      end
      if canonical_counts && canonical_counts.values.sum.zero?
        errors << 'quality_evidence_generated_source_counts_empty'
      end
    when 'skipped'
      unless SKIPPED_RETRIEVAL_STATUSES.include?(retrieval_status)
        errors << 'quality_evidence_retrieval_status_generation_mismatch'
      end
      errors << 'quality_evidence_skipped_context_not_empty' unless context == ''
      errors << 'quality_evidence_skipped_provider_model_present' unless provider_model.nil?
      if canonical_counts && canonical_counts.values.any?(&:positive?)
        errors << 'quality_evidence_skipped_source_counts_nonzero'
      end
    end

    errors.uniq
  end

  def canonical_source_counts(source_counts)
    SOURCE_COUNT_KEYS.to_h do |key|
      raw = source_counts[key] || source_counts[key.to_sym]
      [key, Integer(raw || 0)]
    end
  end
  private_class_method :canonical_source_counts

  def canonical_retrieval_searches(retrieval_searches)
    supplied = retrieval_searches || empty_retrieval_searches
    RETRIEVAL_SEARCH_KEYS.to_h do |key|
      record = value(supplied, key) || {}
      [
        key.to_sym,
        {
          status: value(record, 'status') || 'not_requested',
          duration_ms: Integer(value(record, 'duration_ms') || 0),
          timeout: value(record, 'timeout') == true,
          error: value(record, 'error')
        }
      ]
    end
  end
  private_class_method :canonical_retrieval_searches

  def validated_source_counts(source_counts, errors)
    unless source_counts.is_a?(Hash)
      errors << 'quality_evidence_source_counts_missing'
      return nil
    end

    keys = source_counts.keys.map(&:to_s)
    unless keys.sort == SOURCE_COUNT_KEYS.sort
      errors << 'quality_evidence_source_counts_keys_mismatch'
      return nil
    end

    counts = {}
    SOURCE_COUNT_KEYS.each do |key|
      count = value(source_counts, key)
      unless count.is_a?(Integer) && count >= 0
        errors << 'quality_evidence_source_counts_invalid'
        return nil
      end
      counts[key] = count
    end
    counts
  end
  private_class_method :validated_source_counts

  def validated_retrieval_searches(retrieval_searches, errors)
    unless retrieval_searches.is_a?(Hash)
      errors << 'quality_evidence_retrieval_searches_missing'
      return nil
    end

    unless retrieval_searches.keys.map(&:to_s).sort == RETRIEVAL_SEARCH_KEYS.sort
      errors << 'quality_evidence_retrieval_searches_keys_mismatch'
      return nil
    end

    canonical = {}
    RETRIEVAL_SEARCH_KEYS.each do |key|
      record = value(retrieval_searches, key)
      unless record.is_a?(Hash) && record.keys.map(&:to_s).sort == RETRIEVAL_SEARCH_FIELDS.sort
        errors << 'quality_evidence_retrieval_search_fields_mismatch'
        next
      end

      status = value(record, 'status')
      duration_ms = value(record, 'duration_ms')
      timed_out = value(record, 'timeout')
      error = value(record, 'error')
      errors << 'quality_evidence_retrieval_search_status_invalid' unless RETRIEVAL_SEARCH_STATUSES.include?(status)
      errors << 'quality_evidence_retrieval_search_duration_invalid' unless duration_ms.is_a?(Integer) && duration_ms >= 0
      errors << 'quality_evidence_retrieval_search_timeout_invalid' unless [true, false].include?(timed_out)
      errors << 'quality_evidence_retrieval_search_error_invalid' unless error.nil? || (error.is_a?(String) && !error.empty?)

      valid_relationship = case status
                           when 'completed'
                             timed_out == false && error.nil?
                           when 'error'
                             timed_out == false && error.is_a?(String) && !error.empty?
                           when 'timeout'
                             timed_out == true && error.is_a?(String) && !error.empty?
                           when 'not_requested', 'not_applicable'
                             duration_ms == 0 && timed_out == false && error.nil?
                           else
                             false
                           end
      errors << 'quality_evidence_retrieval_search_state_invalid' unless valid_relationship
      canonical[key] = {
        'status' => status,
        'duration_ms' => duration_ms,
        'timeout' => timed_out,
        'error' => error
      }
    end
    canonical.length == RETRIEVAL_SEARCH_KEYS.length ? canonical : nil
  end
  private_class_method :validated_retrieval_searches

  def value(hash, key)
    hash.key?(key) ? hash[key] : hash[key.to_sym]
  end
  private_class_method :value
end
