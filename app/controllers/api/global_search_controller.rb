# frozen_string_literal: true

module Api
  class GlobalSearchController < ApplicationController
    skip_before_action :verify_authenticity_token

    MAX_RESULTS_PER_SOURCE = 5

    def search
      query = params[:q].to_s.strip

      if query.blank? || query.length < 2
        render json: { results: [], query: query }
        return
      end

      # Instant article lookup (e.g. "art 1382 BW" → direct article match)
      article_results = Search::ArticleLookupService.new(locale: I18n.locale).lookup(query)

      # Search all sources (jurisprudence visible to everyone in autocomplete)
      sources = %i[legislation jurisprudence parliamentary]

      service = Search::UnifiedSearchService.new(locale: I18n.locale)
      results = service.search(query, sources: sources, limit_per_source: MAX_RESULTS_PER_SOURCE)

      render json: {
        query: query,
        articles: article_results,
        legislation: results[:legislation] || [],
        jurisprudence: results[:jurisprudence] || [],
        parliamentary: results[:parliamentary] || []
      }
    rescue StandardError => e
      Rails.logger.error("Global search error: #{e.message}")
      render json: { query: query, articles: [], legislation: [], jurisprudence: [], parliamentary: [] }
    end
  end
end
