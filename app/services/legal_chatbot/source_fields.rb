# frozen_string_literal: true

module LegalChatbot
  # Low-level readers for retrieved-source records (FBL-061, extracted
  # verbatim from the orchestrator). Retrieval hands back a zoo of shapes -
  # hashes with symbol or string keys, AR-ish objects, Fisconet rows without
  # a Belgian NUMAC - and every guard, repair and appender resolves NUMACs
  # and article numbers through these three readers. link_article_number and
  # normalize_article_number remain host methods.
  module SourceFields
    extend ActiveSupport::Concern

    def retrieved_source_numac(source)
      value = source_field(source, :numac, 'numac', :content_numac, 'content_numac')
      legislation_id = source_field(source, :legislation_id, 'legislation_id')
      value ||= "FISCONET_#{legislation_id}" if legislation_id
      value.to_s.presence
    end

    def retrieved_source_article_number(source)
      raw = source_field(source, :article_number, 'article_number', :article, 'article')
      metadata = source_field(source, :metadata, 'metadata')
      raw ||= source_field(metadata, :article_number, 'article_number') if metadata
      title = source_field(source, :article_title, 'article_title')
      raw ||= title.to_s.match(/\bArt(?:ikel|icle)?\.?\s*([[:alnum:]][\w\/.:-]*)/i)&.[](1)
      raw ||= link_article_number(source_field(source, :url, 'url'))
      normalize_article_number(strip_article_prefix(raw)).presence
    end

    def strip_article_prefix(value)
      value.to_s.sub(/\A\s*Art(?:ikel|icle)?\.?\s*/i, '')
    end

    def source_field(source, *keys)
      return nil unless source

      keys.each do |key|
        if source.respond_to?(:[])
          begin
            value = source[key]
            return value unless value.nil?
          rescue KeyError, IndexError, TypeError, NoMethodError, NameError
            nil
          end
        end

        method_name = key.to_s
        next unless source.respond_to?(method_name)

        value = source.public_send(method_name)
        return value unless value.nil?
      end

      nil
    end
  end
end
