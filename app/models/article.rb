# frozen_string_literal: true

# == Schema Information

# Table name: articles

#  id            :integer          not null, primary key
#  language_id   :integer          not null
#  content_numac :string           not null
#  article_type  :string
#  article_title :text
#  article_text  :text
#  created_at    :datetime         not null
#  updated_at    :datetime         not null

# Indexes
#  index_articles_on_content_numac  (content_numac)

# Foreign Keys
#  fk_rails_...  (content_numac => contents.legislation_numac)

# Article represents individual articles within legal documents.
# It's associated with a Content record via the content_numac foreign key.

# @example Creating a new article
#   content = Content.find(1)
#   article = Article.new(content: content, ...)
#   article.save

# @example Finding articles
#   # Find all articles for a specific content
#   articles = Article.where(content_id: 1)

# @see Content The associated content model
class Article < ReadonlyRecord
  include HasLanguage

  # Use explicit table name to avoid Rails conventions

  # Associations
  # ----------------------------------------------------------------------------
  # The Content that this article belongs to.
  # @return [Content] The associated content record
  # @note Uses custom foreign key to reference content.legislation_numac
  belongs_to :content,
             foreign_key: 'content_numac',
             primary_key: 'legislation_numac',
             inverse_of: :articles,
             required: true

  # Validations
  # ----------------------------------------------------------------------------
  # Validates the presence of required fields
  validates :content_numac, presence: true

  # Validates the length of text fields
  validates :article_title, length: { maximum: 65_535 }, allow_blank: true
  validates :article_text, length: { maximum: 16_777_215 }, allow_blank: true
  validates :article_type, length: { maximum: 255 }, allow_blank: true

  # Ensure the associated content exists and is valid
  validates_associated :content

  # Scopes
  # ----------------------------------------------------------------------------

  # Orders articles by their ID (insertion order)
  # @param direction [Symbol] :asc or :desc
  # @return [ActiveRecord::Relation]
  scope :ordered, ->(direction = :asc) { order(id: direction) }

  # Articles for a specific content by numac
  # @param numac [String] The content numac
  # @return [ActiveRecord::Relation]
  scope :for_content, ->(numac) { where(content_numac: numac) }

  # Articles with non-empty text
  # @return [ActiveRecord::Relation]
  scope :with_text, -> { where.not(article_text: ['', nil]) }

  # Articles with a specific type
  # @param type [String] The article type
  # @return [ActiveRecord::Relation]
  scope :of_type, ->(type) { where(article_type: type) if type.present? }

  # Class Methods
  # ----------------------------------------------------------------------------

  # Count articles grouped by type
  # @return [Hash] Type names as keys with counts as values
  def self.count_by_type
    group(:article_type).count
  end

  # Find articles by language and content
  # @param language_id [Integer] The language ID
  # @param content_numac [String] The content numac
  # @return [ActiveRecord::Relation]
  def self.for_language_and_content(language_id, content_numac)
    where(language_id: language_id, content_numac: content_numac).ordered
  end

  # Instance Methods
  # ----------------------------------------------------------------------------

  # Returns a formatted title for display
  # @return [String]
  def display_title
    article_title.presence || "Article #{id}"
  end

  # Checks if the article has substantial text content
  # @return [Boolean]
  def substantial_text?
    article_text.present? && article_text.length > 10
  end

  # Returns a truncated version of the article text
  # @param length [Integer] Maximum length
  # @return [String]
  def excerpt(length = 200)
    return '' unless article_text.present?

    text = article_text.strip
    text.length > length ? "#{text[0...length]}..." : text
  end
end
