# frozen_string_literal: true

# == Schema Information
#
# Table name: updated_laws
#
#  id            :integer          not null, primary key
#  language_id   :integer          not null
#  content_numac :string           not null
#  update_numac  :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#  index_updated_laws_on_content_numac  (content_numac)
#  index_updated_laws_on_updated_numac  (update_numac)
#
# Foreign Keys
#  fk_rails_...  (content_numac => contents.legislation_numac)
#  fk_rails_...  (update_numac => legislation.numac)
#
# UpdatedLaw represents a relationship between a piece of legislation and
# another piece of legislation that updates or modifies it.
# This is used to track how laws reference and update each other.
#
# @example Creating a new updated law relationship
#   content = Content.find_by(legislation_numac: '123456789')
#   updated_law = UpdatedLaw.new(
#     content: content,
#     updated_numac: '987654321',
#     # ... other attributes ...
#   )
#   updated_law.save
#
# @example Accessing related records
#   # Get the content this update belongs to
#   content = updated_law.content
#
#   # Get the legislation that does the updating
#   updating_legislation = updated_law.updating_legislation
#
# @see Content The associated content
# @see Legislation The legislation that does the updating
class UpdatedLaw < ReadonlyRecord
  include HasLanguage

  # Explicit table name configuration
  self.table_name = 'updated_laws'

  # Associations
  # ----------------------------------------------------------------------------

  # The Content this update belongs to.
  # @return [Content] The associated content
  # @note Uses custom foreign key to reference content.legislation_numac
  belongs_to :content,
             foreign_key: 'content_numac',
             primary_key: 'legislation_numac',
             inverse_of: :updated_laws,
             required: true

  # The Legislation that does the updating.
  # @return [Legislation] The legislation that updates the content
  # @note Uses custom foreign key to reference legislation.numac
  belongs_to :updating_legislation,
             foreign_key: 'update_numac',
             primary_key: 'numac',
             class_name: 'Legislation',
             inverse_of: :updated_laws_references,
             optional: true

  # Validations
  # ----------------------------------------------------------------------------

  # Validates the presence of required fields
  validates :content_numac, presence: true

  # Validates the presence of updating legislation
  validates :updating_legislation, presence: true

  # Validates that a content doesn't update itself
  validate :cannot_update_itself

  # Scopes
  # ----------------------------------------------------------------------------

  # Scope to find updates by the updating legislation's Numac
  # @param numac [String] The Numac ID of the updating legislation
  # @return [ActiveRecord::Relation] Matching updated laws
  scope :by_updating_legislation, ->(numac) { where(update_numac: numac) }

  # Class Methods
  # ----------------------------------------------------------------------------

  # Finds or initializes an update relationship
  # @param content_numac [String] The Numac ID of the content being updated
  # @param update_numac [String] The Numac ID of the updating legislation
  # @return [UpdatedLaw] The found or new updated law record
  def self.find_or_initialize_for(content_numac, update_numac)
    find_or_initialize_by(
      content_numac: content_numac,
      update_numac: update_numac
    )
  end

  # Instance Methods
  # ----------------------------------------------------------------------------

  # Returns the updating legislation record in the same language as this update.
  # This ensures the title and other fields match the source page language.
  # @return [Legislation, nil]
  def updating_legislation_in_language
    return nil if update_numac.blank? || language_id.blank?

    Legislation.find_by(numac: update_numac, language_id: language_id)
  end

  # Returns a string representation of the update relationship
  # @return [String] Descriptive string
  def to_s
    "#{content&.legislation&.title} is updated by #{updating_legislation&.title}"
  end

  private

  # Validation to prevent a content from updating itself
  def cannot_update_itself
    return unless content_numac.present? && update_numac.present?
    return unless content_numac == update_numac

    errors.add(:base, 'A piece of legislation cannot update itself')
  end
end
