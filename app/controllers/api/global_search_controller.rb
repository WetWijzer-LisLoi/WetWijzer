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
      
      # Use unified search service
      service = Search::UnifiedSearchService.new(locale: I18n.locale)
      results = service.search(query, limit_per_source: MAX_RESULTS_PER_SOURCE)
      
      render json: {
        query: query,
        legislation: results[:legislation] || [],
        jurisprudence: results[:jurisprudence] || [],
        parliamentary: results[:parliamentary] || []
      }
    rescue => e
      Rails.logger.error("Global search error: #{e.message}")
      render json: { query: query, legislation: [], jurisprudence: [], parliamentary: [] }
    end
  end
end
