# frozen_string_literal: true

# Typed schema for server-stored UI preferences (FBL-042).
#
# The old controller accepted params.to_unsafe_h.slice(...) - any NESTED
# structure under an allowed key went straight into users.ui_preferences
# unchecked and unbounded. This schema defines every known key, its nested
# keys, types, enums and ranges, plus byte caps, and returns stable error
# codes instead of silently dropping garbage.
#
# A JSON null for any known key is valid and deletes it (RFC 7396 merge
# semantics, which the atomic json_patch write honors).
module UiPreferenceSchema
  MAX_PATCH_BYTES = 8_192
  MAX_TOTAL_BYTES = 16_384
  MAX_STRING = 60
  MAX_OBJECT_KEYS = 50

  BOOL = ->(value) { [true, false].include?(value) }
  BOUNDED_STRING = ->(value) { value.is_a?(String) && value.length <= MAX_STRING }
  COORD = ->(value) { value.is_a?(Integer) && value.between?(-10_000, 20_000) }
  SCALAR = ->(value) { BOOL.call(value) || BOUNDED_STRING.call(value) || COORD.call(value) }

  SCHEMA = {
    'theme' => ->(value) { %w[light dark system].include?(value) },
    # Header accent picker and TOC follow toggle: live client writers that
    # audit found silently rejected as unknown_key (their whole debounced
    # batch was dropped for logged-in users).
    'theme_accent' => BOUNDED_STRING,
    'toc_follow_enabled' => BOOL,
    'dark_mode' => BOOL,
    'font_size' => BOUNDED_STRING,
    'article_view' => BOUNDED_STRING,
    'sidebar_collapsed' => BOOL,
    'sidebar_auto_open' => BOOL,
    'toc_collapsed' => BOOL,
    'toc_position' => BOUNDED_STRING,
    'reference_style' => BOUNDED_STRING,
    'reference_highlight' => BOOL,
    'bookmarks_view' => BOUNDED_STRING,
    'copy_format' => BOUNDED_STRING,
    'article_preferences' => lambda { |value|
      value.is_a?(Hash) && value.size <= MAX_OBJECT_KEYS &&
        value.all? { |k, v| k.is_a?(String) && k.length <= MAX_STRING && (v.nil? || SCALAR.call(v)) }
    },
    'chatbot' => lambda { |value|
      value.is_a?(Hash) &&
        (value.keys - %w[intelligence model source reasoningLevel profile]).empty? &&
        value.values.all? { |v| v.nil? || BOUNDED_STRING.call(v) }
    },
    'chatbot_widget' => lambda { |value|
      value.is_a?(Hash) &&
        (value.keys - %w[left top width height expanded corner position]).empty? &&
        value.all? do |k, v|
          v.nil? || (%w[expanded].include?(k) ? BOOL.call(v) : COORD.call(v) || BOUNDED_STRING.call(v))
        end
    }
  }.freeze

  Result = Struct.new(:patch, :errors, keyword_init: true) do
    def valid? = errors.empty?
  end

  # Validates a raw (already permitted-to-hash) patch. Returns a Result with
  # the typed patch and a list of {key:, code:} errors.
  def self.validate(raw)
    errors = []
    return Result.new(patch: {}, errors: [{ key: nil, code: 'not_an_object' }]) unless raw.is_a?(Hash)

    return Result.new(patch: {}, errors: [{ key: nil, code: 'patch_too_large' }]) if raw.to_json.bytesize > MAX_PATCH_BYTES

    patch = {}
    raw.each do |key, value|
      key = key.to_s
      checker = SCHEMA[key]
      if checker.nil?
        errors << { key: key, code: 'unknown_key' }
      elsif value.nil? || checker.call(value)
        patch[key] = value
      else
        errors << { key: key, code: 'invalid_value' }
      end
    end
    Result.new(patch: patch, errors: errors)
  end
end
