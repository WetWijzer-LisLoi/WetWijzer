# frozen_string_literal: true

# == Schema Information
#
# Table name: legislation
#
#  id           :integer          not null, primary key
#  numac        :string(10)       not null
#  law_type_id  :integer          not null
#  year         :integer          not null
#  date         :string(10)       not null
#  title        :text             not null
#  justel       :string(80)       not null
#  mon          :string(80)       not null
#  mon_pdf      :string(80)       not null
#  ov_pdf       :string(80)       not null
#  reflex       :string(80)       not null
#  chamber      :string(80)       not null
#  language_id  :integer          not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_legislation_on_date                              (date)
#  index_legislation_on_language_id                       (language_id)
#  index_legislation_on_language_id_and_date              (language_id,date)
#  index_legislation_on_language_id_and_law_type_id       (language_id,law_type_id)
#  index_legislation_on_language_id_and_title             (language_id,title)
#  index_legislation_on_law_type_id                       (law_type_id)
#  index_legislation_on_numac                             (numac)
#  index_legislation_on_title                             (title)
#  index_legislation_on_year                              (year)
#  unique_index_legislation_on_numac_and_language_id      (numac,language_id) UNIQUE
#

# Represents a legal document in the system, such as laws, decrees, or regulations.
# Each legislation is identified by a unique Numac number and can have content in
# multiple languages. The model handles the core metadata and relationships for
# legal documents in the application.
class Legislation < ReadonlyRecord
  # Include sortable behavior for consistent record ordering
  include Sortable
  include HasLanguage

  # Use custom table name
  self.table_name = 'legislation'

  # == Associations ========================================================

  # The content of this legislation in different formats or versions
  # @return [Content] the associated content record
  has_one :content,
          foreign_key: 'legislation_numac',
          primary_key: 'numac',
          dependent: :destroy,
          inverse_of: :legislation

  # The type of this legislation (references the types table)
  # @return [Type] the associated type record
  belongs_to :type,
             class_name: 'Type',
             foreign_key: 'law_type_id',
             inverse_of: :legislations,
             required: true

  # References from other legislation that update this one
  # @return [Array<UpdatedLaw>] relations where this legislation is the updating_legislation
  has_many :updated_laws_references,
           foreign_key: 'update_numac',
           primary_key: 'numac',
           class_name: 'UpdatedLaw',
           inverse_of: :updating_legislation

  # == Validations ========================================================

  # @!attribute [rw] numac
  #   @return [String] The unique Numac identifier for the legislation
  #   @note Must be present and unique per language
  validates :numac,
            presence: true,
            uniqueness: { scope: :language_id, case_sensitive: false },
            length: { minimum: 3, maximum: 10 }

  # @!attribute [rw] title
  #   @return [String] The title of the legislation
  #   @note Must be present
  validates :title, presence: true

  # @!attribute [rw] date
  #   @return [String] The publication or effective date of the legislation (YYYY-MM-DD format)
  #   @note Must be present and in the correct format
  validates :date,
            presence: true,
            format: { with: /\A\d{4}-\d{2}-\d{2}\z/, message: 'must be in YYYY-MM-DD format' },
            length: { is: 10 }

  # @!attribute [rw] year
  #   @return [Integer] The year of the legislation
  #   @note Must be present and a reasonable year
  validates :year,
            presence: true,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 1800,
              less_than_or_equal_to: Date.current.year + 1
            }

  # Required string fields with length validation
  validates :justel, :mon, :mon_pdf, :ov_pdf, :reflex, :chamber,
            presence: true,
            length: { maximum: 80 }

  # @!attribute [rw] law_type_id
  #   @return [Integer] The type/category of the legislation
  #   @note Must be an integer between 1 and 10 (inclusive)
  validates :law_type_id,
            presence: true,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 1,
              less_than_or_equal_to: 11
            }

  # == Scopes =============================================================

  # Orders legislation by date
  # @param direction [Symbol] the sort direction (:asc or :desc)
  # @return [ActiveRecord::Relation] the ordered scope
  scope :order_by_date, ->(direction = :desc) { order(date: direction) }

  # Orders legislation by title
  # @param direction [Symbol] the sort direction (:asc or :desc)
  # @return [ActiveRecord::Relation] the ordered scope
  scope :order_by_title, ->(direction = :asc) { order(title: direction) }

  # == Search Scopes (Delegated to LawSearchService) =======================

  # Filters legislation by language parameters
  # @param params [Hash] search parameters including language filters
  # @return [ActiveRecord::Relation] the filtered scope
  # @see LawSearchService.by_language
  scope :by_language, ->(params) { LawSearchService.by_language(all, params) }

  # Filters legislation by type parameters
  # @param params [Hash] search parameters including type filters
  # @return [ActiveRecord::Relation] the filtered scope
  # @see LawSearchService.by_type
  scope :by_type, ->(params) { LawSearchService.by_type(all, params) }

  # Filters legislation by title search term
  # @param title [String] the search term to match against titles
  # @return [ActiveRecord::Relation] the filtered scope
  # @see LawSearchService.by_title
  scope :by_title, ->(title) { title.present? ? LawSearchService.by_title(all, title) : all }

  # Applies sorting to the legislation scope
  # @param params [Hash] parameters containing sort field and direction
  # @return [ActiveRecord::Relation] the sorted scope
  # @see LawSearchService.apply_sort
  scope :apply_sort, ->(params) { LawSearchService.apply_sort(all, params) }

  # == Class Methods ======================================================

  # Performs a full-text search across legislation records
  # @param params [Hash] search parameters including query, filters, and pagination
  # @return [ActiveRecord::Relation] the search results
  # @see LawSearchService.search
  def self.search(params)
    LawSearchService.search(params)
  end

  # == Instance Methods ===================================================

  # Returns the parameter value used in URLs
  # @return [String] the Numac identifier
  def to_param
    numac
  end
end
