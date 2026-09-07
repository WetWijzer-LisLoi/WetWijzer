# frozen_string_literal: true

# == Schema Information
#
# Table name: types
#
#  id       :integer          not null, primary key
#  law_type :string(11)       not null
#
# Indexes
#
#  index_types_on_law_type  (law_type) UNIQUE
#
# Type represents the classification or category of a piece of legislation.
# This model allows for categorization of laws and regulations (e.g., "decree", "law", "regulation").

class Type < ReadonlyRecord
  # Explicit table name configuration
  self.table_name = 'types'
  self.primary_key = 'id'

  # == Validations ========================================================

  # @!attribute [rw] law_type
  #   @return [String] The type of law (e.g., "grondwet", "wet", "decreet", "ordonnantie", "besluit")
  #   @note Must be present and unique
  validates :law_type,
            presence: true,
            uniqueness: { case_sensitive: false },
            length: { maximum: 11 }

  # == Associations =======================================================

  # The legislations that belong to this type
  # @return [ActiveRecord::Associations::CollectionProxy<Legislation>] collection of associated legislations
  has_many :legislations,
           foreign_key: 'law_type_id',
           inverse_of: :type,
           dependent: :restrict_with_error

  # == Instance Methods ===================================================

  # Returns a string representation of the type
  # @return [String] The law_type value
  def to_s
    law_type
  end

  # Returns a display-friendly name for the type
  # @return [String] A formatted display name
  def display_name
    I18n.t("types.#{law_type.downcase}", default: law_type.humanize)
  end
end
