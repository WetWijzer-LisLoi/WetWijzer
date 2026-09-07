# frozen_string_literal: true

# == Schema Information
#
# Table name: languages
#
#  id       :integer          not null, primary key
#  language :string
#
# Language represents an official language used for legislation content in Belgium.
# This model supports the bilingual nature of Belgian legislation (Dutch and French).
#
# @example Creating a new language
#   language = Language.new(language: 'nl')
#   language.save
#
# @example Finding a language
#   language = Language.find_by(language: "nl")
#
# @example Getting all available languages
#   languages = Language.all
class Language < ReadonlyRecord
  # Explicit table name configuration
  self.table_name = 'languages'

  # Validations
  # ----------------------------------------------------------------------------

  # Validates the presence of the language code
  validates :language, presence: true, uniqueness: true

  # Validates the format of the language code (2-letter ISO 639-1 code)
  validates :language, format: { with: /\A[a-z]{2}\z/, message: 'must be a 2-letter ISO 639-1 code' }

  # Class Methods
  # ----------------------------------------------------------------------------

  # Returns a hash of language codes to display names for official Belgian languages
  # @return [Hash] Language codes mapped to their display names
  # @note Only Dutch ("nl") and French ("fr") are official languages for legal texts in Belgium
  def self.available_languages
    {
      'nl' => 'Nederlands',
      'fr' => 'Français'
    }
  end

  # Instance Methods
  # ----------------------------------------------------------------------------

  # Returns the display name for the language
  # @return [String] The display name of the language
  # Returns the display name of the language
  # @return [String] The display name (e.g., "Dutch" for "nl")
  def display_name
    I18n.t("languages.#{code}", default: code.upcase)
  end

  # Returns the language code in uppercase
  # @return [String] Uppercase language code (e.g., "NL")
  def code_upcase
    code&.upcase
  end

  # Checks if this is the default language
  # @return [Boolean] True if this is the default language
  def default?
    code == I18n.default_locale.to_s
  end
end
