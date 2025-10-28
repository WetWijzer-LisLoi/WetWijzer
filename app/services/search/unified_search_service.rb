# frozen_string_literal: true

module Search
  class UnifiedSearchService
    ADAPTERS = {
      legislation: LegislationAdapter,
      jurisprudence: JurisprudenceAdapter,
      parliamentary: ParliamentaryAdapter
    }.freeze

    attr_reader :locale

    def initialize(locale: :nl)
      @locale = locale
      @adapters = {}
    end

    # Search across multiple sources
    # @param query [String] search query
    # @param sources [Array<Symbol>] which sources to search (default: all)
    # @param filters [Hash] filters to apply
    # @param limit_per_source [Integer] max results per source
    # @return [Hash] results grouped by source
    def search(query, sources: ADAPTERS.keys, filters: {}, limit_per_source: 5)
      results = {}
      
      sources.each do |source|
        adapter = get_adapter(source)
        next unless adapter

        source_results = adapter.search(query, filters: filters, limit: limit_per_source)
        results[source] = source_results if source_results.any?
      end

      results
    end

    # Search all sources and return combined, ranked results
    # @param query [String] search query
    # @param limit [Integer] total max results
    # @return [Array<Hash>] combined results sorted by score
    def search_combined(query, filters: {}, limit: 20)
      all_results = []

      ADAPTERS.keys.each do |source|
        adapter = get_adapter(source)
        next unless adapter

        results = adapter.search(query, filters: filters, limit: limit)
        all_results.concat(results)
      end

      # Sort by score descending, take top results
      all_results.sort_by { |r| -r[:score] }.first(limit)
    end

    # Get context for chatbot from multiple sources
    # @param items [Array<Hash>] items with :source and :id
    # @return [Array<Hash>] contexts
    def get_contexts(items)
      contexts = []

      items.group_by { |i| i[:source] }.each do |source, source_items|
        adapter = get_adapter(source)
        next unless adapter

        ids = source_items.map { |i| i[:id] }
        contexts.concat(adapter.get_contexts(ids))
      end

      contexts.compact
    end

    # Get single context
    def get_context(source, id)
      adapter = get_adapter(source)
      return nil unless adapter

      adapter.get_context(id)
    end

    # Available sources
    def available_sources
      ADAPTERS.keys.map do |key|
        adapter = get_adapter(key)
        {
          key: key,
          label: adapter.source_label(locale)
        }
      end
    end

    private

    def get_adapter(source)
      source = source.to_sym
      return nil unless ADAPTERS.key?(source)

      @adapters[source] ||= ADAPTERS[source].new
    end
  end
end
