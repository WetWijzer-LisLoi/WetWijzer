# frozen_string_literal: true

# The values a chatbot client may send as metadata beside a report or a
# feedback (WW-SEC-07). These fields hold no question text, but they are still
# raw request values: without a vocabulary any prose was stored, exported and
# logged. Each reader returns the canonical value, nil when the field is
# absent, or INVALID.
module ChatbotMetadataVocabulary
  INVALID = :invalid
  MAX_BYTES = 64
  LANGUAGES = StarterQuestionCatalog::LANGUAGES
  FEEDBACK_TYPES = %w[positive negative].freeze
  # Kept as sent by browsers holding an older preference; not categories.
  LEGACY_SOURCES = %w[all custom].freeze

  module_function

  def language(value)
    token(value) { |text| LANGUAGES.include?(text) ? text : INVALID }
  end

  def intelligence(value)
    token(value) { |text| LegalChatbot::ModelsConfig::INTELLIGENCE_LEVELS.key?(text) ? text : INVALID }
  end

  def feedback_type(value)
    token(value) { |text| FEEDBACK_TYPES.include?(text) ? text : INVALID }
  end

  # One category, the client's comma-joined selection of categories, or a
  # legacy value. A selection is stored in the canonical category order.
  def source(value)
    token(value) do |text|
      next text if LEGACY_SOURCES.include?(text)

      parts = text.split(',').map(&:strip)
      next INVALID unless parts.any? && parts.all? { |part| ChatbotSourceCategories::ALL.include?(part) }

      ChatbotSourceCategories::ALL.select { |category| parts.include?(category) }.join(',')
    end
  end

  def invalid?(value)
    value == INVALID
  end

  # Whether a logged parameter may be shown as sent: only a known value is.
  def loggable?(key, value)
    reader = { 'source' => :source, 'language' => :language, 'intelligence' => :intelligence,
               'feedback_type' => :feedback_type }[key.to_s]
    reader.nil? || !invalid?(public_send(reader, value))
  end

  def token(value)
    return nil if value.nil? || value == ''
    return INVALID unless value.is_a?(String) && value.bytesize <= MAX_BYTES

    yield value.strip.downcase
  end
end
