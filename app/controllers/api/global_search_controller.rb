# frozen_string_literal: true

module Api
  class GlobalSearchController < ApplicationController
    MAX_RESULTS_PER_SOURCE = 5

    def search
      query = params[:q].to_s.strip

      if query.blank? || query.length < 2
        render json: { results: [], query: query }
        return
      end

      t_req = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Instant article lookup (e.g. "art 1382 BW" → direct article match)
      article_results = Search::ArticleLookupService.new(locale: I18n.locale).lookup(query)
      articles_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_req) * 1000).round(1)

      # Search all sources (jurisprudence visible to everyone in autocomplete)
      sources = %i[legislation jurisprudence parliamentary]

      service = Search::UnifiedSearchService.new(locale: I18n.locale)
      results = service.search(query, sources: sources, limit_per_source: MAX_RESULTS_PER_SOURCE)

      # Per-adapter latency attribution; q_hash instead of the raw query
      # because search text is legal PII (see the chatbot GET-route removal).
      timings = service.last_timings_ms || {}
      total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_req) * 1000).round(1)
      Rails.logger.info(
        "[SEARCH-TIMING] q_hash=#{Digest::SHA256.hexdigest(query)[0, 12]} " \
        "len=#{query.length} total=#{total_ms}ms articles=#{articles_ms}ms " \
        "legislation=#{timings[:legislation] || 0}ms " \
        "jurisprudence=#{timings[:jurisprudence] || 0}ms " \
        "parliamentary=#{timings[:parliamentary] || 0}ms"
      )

      failed = service.failed_sources || {}
      if failed.size == sources.size
        # Every corpus adapter failed: that is an outage, not empty results.
        response.set_header('Retry-After', '30')
        return render json: { error: { code: 'search_unavailable' }, query: query },
                      status: :service_unavailable
      end

      payload = {
        query: query,
        articles: article_results,
        legislation: results[:legislation] || [],
        jurisprudence: results[:jurisprudence] || [],
        parliamentary: results[:parliamentary] || []
      }
      # FBL-064: a partially degraded answer says so instead of looking
      # healthy (codes only, no exception text).
      payload[:degraded_sources] = failed.keys if failed.any?
      render json: payload
    rescue StandardError => e
      # FBL-044: a dependency failure must not masquerade as "no results".
      # Stable machine code, class-only logging, and an explicit retry hint.
      Rails.logger.error("Global search error: #{e.class}")
      response.set_header('Retry-After', '30')
      render json: { error: { code: 'search_unavailable' }, query: query },
             status: :service_unavailable
    end
  end
end
