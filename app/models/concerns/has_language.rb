# frozen_string_literal: true

# == HasLanguage
#
# Shared concern to enforce the canonical WetWijzer language mapping
# (Dutch = 1, French = 2) and to expose helper methods for inspecting or
# transforming a model's language. Include this in any ActiveRecord model that
# persists a `language_id` column.
module HasLanguage
  extend ActiveSupport::Concern

  LANGUAGE_IDS = { nl: 1, fr: 2 }.freeze
  LANGUAGE_LOCALES = { nl: :nl, fr: :fr }.freeze

  included do
    validates :language_id,
              presence: true,
              inclusion: { in: LANGUAGE_IDS.values }
  end

  class_methods do
    # Resolves an input (symbol, string, or numeric) into a canonical language ID.
    # Returns nil when the input cannot be mapped.
    def language_id_for(value)
      case value
      when Integer
        LANGUAGE_IDS.values.include?(value) ? value : nil
      when String, Symbol
        LANGUAGE_IDS[value.to_sym]
      end
    end

    # Resolves an input into an I18n locale, e.g. :nl or :fr.
    def language_locale_for(value)
      LANGUAGE_LOCALES[language_key_for(value)]
    end

    # Resolves an input into the symbolic language key (:nl or :fr).
    def language_key_for(value)
      case value
      when Integer
        LANGUAGE_IDS.key(value)
      when String, Symbol
        key = value.to_sym
        LANGUAGE_IDS.key?(key) ? key : nil
      end
    end
  end

  # @return [Boolean] true when the record stores Dutch content
  def dutch?
    language_id == LANGUAGE_IDS[:nl]
  end

  # @return [Boolean] true when the record stores French content
  def french?
    language_id == LANGUAGE_IDS[:fr]
  end

  # @return [Symbol, nil] :nl or :fr, nil when language_id unset
  def language_key
    LANGUAGE_IDS.key(language_id)
  end

  # @return [Symbol, nil] locale mapped via `LANGUAGE_LOCALES`
  def language_locale
    LANGUAGE_LOCALES[language_key]
  end
end
