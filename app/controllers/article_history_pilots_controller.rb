# frozen_string_literal: true

# The article-history pilot page (ArticleHistoryPilot): one article's wordings over time, from Justel's archived
# versions, with a version selector, a day lookup and a word comparison of two versions. Local only: it answers
# 404 in production and wherever the pilot database is absent.
class ArticleHistoryPilotsController < ApplicationController
  ISO_DAY = /\A\d{4}-\d{2}-\d{2}\z/

  def show
    return head(:not_found) unless ArticleHistoryPilot.available?

    @language = params[:language].presence_in(%w[nl fr]) || (I18n.locale.to_s == 'fr' ? 'fr' : 'nl')
    @numac = params[:numac].to_s
    @article = params[:article].to_s
    pilot = ArticleHistoryPilot.new
    begin
      @variants = pilot.variants(@numac, @language, @article)
      return head(:not_found) if @variants.empty?

      @variant = params[:variant].to_s.presence_in(@variants) || @variants.first
      @versions = pilot.versions(@numac, @language, @article, @variant)
      @day = params[:day].to_s if params[:day].to_s.match?(ISO_DAY)
      @selected = select_version(pilot)
      @compared = @versions.find { |version| version.id.to_s == params[:compare].to_s && version.text? }
      @diff = ArticleHistoryPilot.word_diff(@compared.body, @selected.body) if @compared && @selected&.text?
    ensure
      pilot.close
    end
  end

  private

  def select_version(pilot)
    return pilot.version_on(@numac, @language, @article, @variant, @day) if @day

    @versions.find { |version| version.id.to_s == params[:version].to_s } ||
      @versions.rfind(&:text?)
  end
end
