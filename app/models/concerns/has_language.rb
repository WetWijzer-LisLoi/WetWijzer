# frozen_string_literal: true

# == HasLanguage
#
# Shared concern to enforce the canonical WetWijzer language mapping
# (Dutch = 1, French = 2, German = 3) and to expose helper methods for
# inspecting or transforming a model's language. Include this in any
# ActiveRecord model that persists a `language_id` column.
#
# Dutch and French are the languages of the whole corpus and of every site.
# German rows exist since updater v0.894 (proven Staatsblatt notices, see
# docs/ops/german-corpus-plan-2026-09-27.md) and are served by the German site
# alone (phase B of that plan); see Legislation.served_on_german_site.
module HasLanguage
  extend ActiveSupport::Concern

  LANGUAGE_IDS = { nl: 1, fr: 2, de: 3 }.freeze
  LANGUAGE_LOCALES = { nl: :nl, fr: :fr, de: :de }.freeze

  # The languages the Dutch and French sites serve, and the only ones a
  # lookup by NUMAC alone may land on on any site (compare, sitemaps, the
  # case-law and parliamentary links, the chatbot).
  SITE_LANGUAGE_IDS = [LANGUAGE_IDS[:nl], LANGUAGE_IDS[:fr]].freeze

  GERMAN_LANGUAGE_ID = LANGUAGE_IDS[:de]

  included do
    validates :language_id,
              presence: true,
              inclusion: { in: LANGUAGE_IDS.values }

    # The rows the Dutch and French sites serve. The German rows (language_id
    # 3) stay invisible to every read path of those sites, and to every lookup
    # by NUMAC alone: such a lookup goes through this scope, so it can never
    # land on one. The German site adds them through
    # Legislation.served_on_german_site.
    scope :in_site_languages, -> { where(language_id: SITE_LANGUAGE_IDS) }
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

    # Resolves an input into an I18n locale, e.g. :nl, :fr or :de.
    def language_locale_for(value)
      LANGUAGE_LOCALES[language_key_for(value)]
    end

    # Resolves an input into the symbolic language key (:nl, :fr or :de).
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

  # @return [Boolean] true when the record stores German content
  def german?
    language_id == LANGUAGE_IDS[:de]
  end

  # @return [Symbol, nil] :nl, :fr or :de, nil when language_id unset
  def language_key
    LANGUAGE_IDS.key(language_id)
  end

  # @return [Symbol, nil] locale mapped via `LANGUAGE_LOCALES`
  def language_locale
    LANGUAGE_LOCALES[language_key]
  end
end
