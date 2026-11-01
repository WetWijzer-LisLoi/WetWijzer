# frozen_string_literal: true

module LegalChatbot
  # The per-answer metadata record (schema v1) that the browser history, the
  # consented standard history, the encrypted history, conversation imports
  # and every export carry.
  #
  # Four parts stay separate, because each answers a different question:
  #
  # - requested: what the browser asked for at send time (its own snapshot);
  # - attempt:   what the LAST final-answer generation call did, from server
  #              evidence only (a recorded request alone is not a dispatch);
  # - guard:     the existing citation_guard_outcome, copied unchanged;
  # - outcome:   what the visible answer is, in this record's own vocabulary.
  #
  # Every value is an enum or an id from a server allowlist, and nil means
  # unknown. Nothing is inferred from the selection, a billing receipt, a
  # translation, an embedding call or an earlier attempt. A record that comes
  # in through an import is a claimed historical snapshot: the server marks it
  # "imported" and it is never presented as verified.
  module AnswerMeta
    VERSION = 1

    SOURCES = %w[live imported].freeze
    RESPONSES = %w[received none].freeze
    GENERATIONS = %w[valid incomplete empty refusal error].freeze
    GUARDS = %w[analysis verified_sources_fallback refusal].freeze
    # generated:         a model answer, accepted by the guards, is shown;
    # verified_recovery: the model draft was rejected and a substantive answer
    #                    derived from the verified sources is shown instead;
    # sources_only:      the draft was rejected and only a list of the verified
    #                    sources is shown;
    # withheld:          the answer was refused;
    # the rest name why no answer is shown at all.
    STATUSES = %w[
      generated verified_recovery sources_only withheld no_model_answer timeout incomplete error cancelled
      not_started unknown
    ].freeze
    TRANSLATIONS = %w[translated mapped french_fallback].freeze
    EFFORTS = %w[none low medium high].freeze

    TOP_KEYS = %w[v source requested attempt guard outcome].freeze
    REQUESTED_KEYS = %w[category intelligence model research_depth reasoning_effort linked_research].freeze
    ATTEMPT_KEYS = %w[model dispatched response generation calls_started].freeze
    OUTCOME_KEYS = %w[status model model_version category research_depth reasoning_effort translation].freeze

    # Checked BEFORE any schema walk, so a hostile import costs a bounded,
    # shallow scan and nothing else.
    MAX_BYTES = 2048
    MAX_DEPTH = 3
    MAX_NODES = 48
    MAX_CALLS = 4
    MAX_ID_LENGTH = 64

    module_function

    # ── Allowlists (historical ids included, never mapped to a replacement) ──

    # Today's models plus the retired ids history can still hold. A retired
    # id stays exactly what it was: RETIRED_MODEL_REPLACEMENTS is for new
    # selections and is never consulted here.
    def model_ids
      LegalChatbotService::AVAILABLE_MODELS.keys | LegalChatbotService::RETIRED_MODEL_NAMES.keys
    end

    def categories
      LegalChatbot::Profiles::CHATBOT_PROFILES.keys
    end

    def intelligences
      LegalChatbotService::INTELLIGENCE_LEVELS.keys
    end

    def research_depths
      LegalChatbotService::RESEARCH_DEPTHS.keys
    end

    # The provider ids a model's exact revision may be reported as: the
    # application id and the provider-side id the client sends.
    def expected_provider_ids(model)
      config = LegalChatbotService::AVAILABLE_MODELS[model.to_s]
      return [] unless config

      [model.to_s, config[:api_model], config[:bedrock_inference_profile]].compact.map(&:to_s).uniq
    end

    # An exact revision is kept only when it is one of the model's own
    # provider ids or such an id with a revision suffix, by the same allowlist
    # rule GenerationTrace applies. A retired model has no expected ids, so
    # its version is always unknown.
    def valid_model_version?(model, version)
      return false unless version.is_a?(String) && !version.empty?

      expected = expected_provider_ids(model)
      return false if expected.empty?

      GenerationTrace.safe_provider_model(version, expected: expected, fallback: nil) == version
    end

    # ── Live records ──

    # The requested part, as the server received it, each value kept only
    # when it is in its allowlist (an unknown value is unknown, not repaired).
    def requested(category:, intelligence:, model:, research_depth:, reasoning_effort:, linked_research:)
      {
        'category' => allowed(category, categories),
        'intelligence' => allowed(intelligence, intelligences),
        'model' => allowed(model, model_ids),
        'research_depth' => allowed(research_depth, research_depths),
        'reasoning_effort' => allowed(reasoning_effort, EFFORTS),
        'linked_research' => boolean_or_nil(linked_research)
      }
    end

    # A provenance with nothing known but the outcome status: no attempt, no
    # guard, every outcome field nil. For answers the service never made
    # (events before it existed) and for callers that cannot ask it.
    def provenance(status:)
      outcome = OUTCOME_KEYS.to_h { |key| [key, nil] }
      outcome['status'] = STATUSES.include?(status) ? status : 'unknown'
      { 'attempt' => nil, 'guard' => nil, 'outcome' => outcome }
    end

    # A whole live record from server-computed provenance (attempt, guard,
    # outcome as Orchestrator#answer_provenance_for returns them).
    def live(requested:, provenance:)
      provenance = stringify(provenance || {})
      record = {
        'v' => VERSION,
        'source' => 'live',
        'requested' => requested,
        'attempt' => provenance['attempt'],
        'guard' => provenance['guard'],
        'outcome' => provenance['outcome'] || provenance(status: 'unknown')['outcome']
      }
      normalize(record, source: 'live')
    end

    # ── Validation (fail-closed for the WHOLE object) ──

    # Returns the validated record with the server-assigned source, or nil.
    # A nil result means the caller keeps the message and drops the meta.
    def normalize(candidate, source:)
      return nil unless SOURCES.include?(source)

      record = shallow_safe_copy(candidate)
      return nil unless record
      return nil unless JSON.generate(record).bytesize <= MAX_BYTES
      return nil unless record['v'] == VERSION && record['v'].is_a?(Integer)
      return nil unless exact_keys?(record, TOP_KEYS)

      requested = record['requested']
      attempt = record['attempt']
      outcome = record['outcome']
      return nil unless requested_valid?(requested)
      return nil unless attempt.nil? || attempt_valid?(attempt)
      return nil unless record['guard'].nil? || GUARDS.include?(record['guard'])
      return nil unless outcome_valid?(outcome)
      return nil unless generated_consistent?(record)

      record.merge('source' => source)
    rescue JSON::GeneratorError, EncodingError
      nil
    end

    def requested_valid?(value)
      return false unless value.is_a?(Hash) && exact_keys?(value, REQUESTED_KEYS)

      allowed_or_nil?(value['category'], categories) &&
        allowed_or_nil?(value['intelligence'], intelligences) &&
        allowed_or_nil?(value['model'], model_ids) &&
        allowed_or_nil?(value['research_depth'], research_depths) &&
        allowed_or_nil?(value['reasoning_effort'], EFFORTS) &&
        [true, false, nil].include?(value['linked_research'])
    end

    def attempt_valid?(value)
      return false unless value.is_a?(Hash) && exact_keys?(value, ATTEMPT_KEYS)

      calls = value['calls_started']
      allowed_or_nil?(value['model'], model_ids) &&
        [true, false, nil].include?(value['dispatched']) &&
        allowed_or_nil?(value['response'], RESPONSES) &&
        allowed_or_nil?(value['generation'], GENERATIONS) &&
        (calls.nil? || (calls.is_a?(Integer) && calls.between?(0, MAX_CALLS))) &&
        # A model is named only for a call that was actually written.
        (value['model'].nil? || value['dispatched'] == true)
    end

    def outcome_valid?(value)
      return false unless value.is_a?(Hash) && exact_keys?(value, OUTCOME_KEYS)
      return false unless STATUSES.include?(value['status'])

      generated = value['status'] == 'generated'
      # A generated answer names the model that generated it; an unknown
      # identity belongs in a record that does not claim generation.
      model_ok = generated ? allowed(value['model'], model_ids).present? : value['model'].nil?
      version = value['model_version']
      version_ok = version.nil? || (generated && valid_model_version?(value['model'], version))

      model_ok && version_ok &&
        allowed_or_nil?(value['category'], categories) &&
        allowed_or_nil?(value['research_depth'], research_depths) &&
        allowed_or_nil?(value['reasoning_effort'], EFFORTS) &&
        allowed_or_nil?(value['translation'], TRANSLATIONS)
    end

    # "generated" holds only together with its evidence: the guard's
    # "analysis" and a last attempt that was dispatched, answered and valid,
    # by the same model the outcome names. Anything else is not a generated
    # record, whoever built it.
    def generated_consistent?(record)
      return true unless record.dig('outcome', 'status') == 'generated'

      attempt = record['attempt']
      record['guard'] == 'analysis' && attempt.is_a?(Hash) &&
        attempt['dispatched'] == true && attempt['response'] == 'received' &&
        attempt['generation'] == 'valid' && attempt['model'] == record.dig('outcome', 'model')
    end

    # A bounded copy that refuses anything outside the record's value shapes
    # before any schema check runs: objects with string keys, strings,
    # booleans, small integers and null, at most MAX_DEPTH levels and
    # MAX_NODES values. Arrays and floats are refused. Request parameters are
    # walked as they are, so nothing is deep-converted before this scan.
    def shallow_safe_copy(value)
      return nil unless object?(value)

      nodes = 0
      copy = lambda do |item, depth|
        nodes += 1
        raise ArgumentError if nodes > MAX_NODES || depth > MAX_DEPTH

        case item
        when ->(candidate) { object?(candidate) }
          raise ArgumentError if item.keys.length > MAX_NODES

          item.each_pair.with_object({}) do |(key, child), out|
            raise ArgumentError unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError if key.to_s.length > MAX_ID_LENGTH

            out[key.to_s] = copy.call(child, depth + 1)
          end
        when String
          raise ArgumentError if item.length > GenerationTrace::PROVIDER_MODEL_LIMIT || !item.valid_encoding?

          item
        when true, false, nil then item
        when Integer
          raise ArgumentError unless item.between?(0, 1000)

          item
        else
          raise ArgumentError
        end
      end
      copy.call(value, 1)
    rescue ArgumentError
      nil
    end

    def object?(value)
      value.is_a?(Hash) || (defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters))
    end

    def exact_keys?(hash, keys)
      hash.keys.sort == keys.sort
    end

    def allowed(value, list)
      text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
      text if text && list.include?(text)
    end

    def allowed_or_nil?(value, list)
      value.nil? || (value.is_a?(String) && list.include?(value))
    end

    def boolean_or_nil(value)
      case value
      when true, 'true', '1', 1 then true
      when false, 'false', '0', 0 then false
      end
    end

    def stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(key, child), out| out[key.to_s] = stringify(child) }
      else value
      end
    end
  end
end
