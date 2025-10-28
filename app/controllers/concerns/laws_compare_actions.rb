# frozen_string_literal: true

# == LawsCompareActions Concern
#
# Extracted from LawsController (Product Evolution Target #2).
# Contains the bilingual comparison action.
#
# @see LawsController
module LawsCompareActions
  extend ActiveSupport::Concern

  # GET /laws/:numac/compare
  #
  # Displays a side-by-side comparison of both language versions (NL and FR).
  # Useful for bilingual users or translators who need to see both versions simultaneously.
  #
  # @return [void]
  def compare
    @title = "#{t(:compare, default: 'Vergelijken')} - #{@law&.numac}"

    # Load legislation for both languages
    @law_nl = Legislation.find_by(numac: params[:numac], language_id: 1)
    @law_fr = Legislation.find_by(numac: params[:numac], language_id: 2)

    # Load content for both languages
    @content_nl = Content.includes(:legislation).find_by(legislation_numac: params[:numac], language_id: 1)
    @content_fr = Content.includes(:legislation).find_by(legislation_numac: params[:numac], language_id: 2)

    # Load articles for both languages
    @articles_nl = Article.where(content_numac: params[:numac], language_id: 1).order(:id)
    @articles_fr = Article.where(content_numac: params[:numac], language_id: 2).order(:id)
  end
end
