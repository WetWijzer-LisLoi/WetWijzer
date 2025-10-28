# frozen_string_literal: true

# == Schema Information
#
# Table name: exdecs
#
#  id            :integer          not null, primary key
#  language_id   :integer          not null
#  content_numac :string           not null
#  exdec_numac   :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#  index_exdecs_on_content_numac  (content_numac)
#
# Foreign Keys
#  fk_rails_...  (content_numac => contents.legislation_numac)
#
# Exdec (Executive Decision) represents executive decisions related to legislation.
# These are typically administrative decisions that implement or interpret laws.
#
# @example Creating a new executive decision
#   content = Content.find_by(legislation_numac: '123456789')
#   exdec = Exdec.new(
#     content: content,
#     # ... other attributes ...
#   )
#   exdec.save
#
# @example Accessing related records
#   # Get the content this decision belongs to
#   content = exdec.content
#
#   # Get the legislation through content
#   legislation = exdec.content.legislation
#
# @see Content The associated content
# @see Legislation The legislation this decision relates to
class Exdec < ReadonlyRecord
  include HasLanguage

  # Explicit table name configuration
  self.table_name = 'exdecs'

  # Associations
  # ----------------------------------------------------------------------------

  # The Content this executive decision belongs to.
  # @return [Content] The associated content
  # @note Uses custom foreign key to reference content.legislation_numac
  belongs_to :content,
             foreign_key: 'content_numac',
             primary_key: 'legislation_numac',
             inverse_of: :exdecs,
             required: true

  # The Legislation referenced by exdec_numac (the executive decision itself).
  # @return [Legislation, nil]
  belongs_to :executive_legislation,
             foreign_key: 'exdec_numac',
             primary_key: 'numac',
             class_name: 'Legislation',
             optional: true

  # Validations
  # ----------------------------------------------------------------------------

  # Validates the presence of required fields
  validates :content_numac, presence: true

  # Validates the length of string fields
  validates :exdec_numac, length: { maximum: 50 }, allow_blank: true

  # Ensure the associated content exists and is valid
  validates_associated :content

  # Validations
  # ----------------------------------------------------------------------------

  # Validates the presence of content association
  validates :content, presence: true

  # Scopes
  # ----------------------------------------------------------------------------
  # Example of a custom scope:
  # scope :recent, -> { order(created_at: :desc) }

  # Class Methods
  # ----------------------------------------------------------------------------
  # Example of a class method:
  # def self.search(query)
  #   joins(content: :legislation)
  #     .where("legislation.title ILIKE :query OR exdecs.description ILIKE :query",
  #            query: "%#{query}%")
  # end

  # Instance Methods
  # ----------------------------------------------------------------------------
  # Returns the executive legislation record in the same language as this record.
  # Ensures the title and details match the source page's language.
  # @param cache [Hash] Optional hash of numac => Legislation for batch loading
  # @return [Legislation, nil]
  def executive_legislation_in_language(cache = nil)
    return nil if exdec_numac.blank? || language_id.blank?

    # Use cache if provided (prevents N+1 queries)
    if cache.is_a?(Hash)
      result = cache[exdec_numac]
      if result.nil?
        Rails.logger.warn("[EXDEC CACHE MISS] numac=#{exdec_numac}, cache_size=#{cache.size}, has_key=#{cache.key?(exdec_numac)}")
      end
      result
    else
      # Fallback to direct query if cache not available
      Rails.logger.warn("[EXDEC NO CACHE] numac=#{exdec_numac}, cache_class=#{cache.class}, cache_nil=#{cache.nil?}")
      Legislation.find_by(numac: exdec_numac, language_id: language_id)
    end
  end
  # Example of an instance method:
  # def formatted_decision_date
  #   decision_date&.strftime('%d/%m/%Y')
  # end

  # Example of a method that delegates to the associated content:
  # delegate :legislation, to: :content, allow_nil: true
end
