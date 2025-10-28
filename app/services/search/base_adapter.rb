# frozen_string_literal: true

module Search
  class BaseAdapter
    attr_reader :options

    def initialize(options = {})
      @options = options
    end

    # Search for items matching query with filters
    # @param query [String] search query
    # @param filters [Hash] optional filters
    # @param limit [Integer] max results
    # @return [Array<Hash>] results with :id, :title, :subtitle, :url, :source, :score
    def search(query, filters: {}, limit: 10)
      raise NotImplementedError, "#{self.class}#search must be implemented"
    end

    # Get full content for context retrieval (for chatbot)
    # @param id [String, Integer] item identifier
    # @return [Hash] with :id, :title, :content, :metadata
    def get_context(id)
      raise NotImplementedError, "#{self.class}#get_context must be implemented"
    end

    # Get multiple contexts efficiently
    # @param ids [Array] item identifiers
    # @return [Array<Hash>]
    def get_contexts(ids)
      ids.map { |id| get_context(id) }.compact
    end

    # Source identifier
    def source_name
      raise NotImplementedError
    end

    # Human-readable source label
    def source_label(locale = :nl)
      raise NotImplementedError
    end

    protected

    def truncate(text, length = 200)
      return '' if text.blank?
      text.length > length ? "#{text[0...length]}..." : text
    end
  end
end
