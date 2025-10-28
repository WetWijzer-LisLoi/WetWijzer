# frozen_string_literal: true

class ArticleModification < ApplicationRecord
  belongs_to :language, optional: true

  scope :abolished, -> { where(change_type: 'abolished') }
  scope :for_numac, ->(numac) { where(content_numac: numac) }
  scope :for_article, ->(numac, article_title) { where(content_numac: numac, article_title: article_title) }

  # Check if a specific article is abolished
  def self.article_abolished?(numac, article_title, language_id = 1)
    where(content_numac: numac, article_title: article_title, change_type: 'abolished', language_id: language_id).exists?
  end

  # Get abolition date for an article
  def self.abolition_date(numac, article_title, language_id = 1)
    where(content_numac: numac, article_title: article_title, change_type: 'abolished', language_id: language_id)
      .order(effective_date: :desc)
      .pick(:effective_date)
  end

  # Get all abolished articles for a law
  def self.abolished_articles_for_law(numac, language_id = 1)
    where(content_numac: numac, change_type: 'abolished', language_id: language_id)
      .pluck(:article_title, :effective_date)
      .to_h
  end
end
