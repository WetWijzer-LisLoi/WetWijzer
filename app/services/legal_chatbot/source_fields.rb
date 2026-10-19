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
      # EU works have CELEX identities, never a Belgian NUMAC. Do not let a
      # copied NUMAC on a forged/modified corpus record enter the domestic lane.
      return if eurlex_corpus_source?(source)

      value = source_field(source, :numac, 'numac', :content_numac, 'content_numac')
      legislation_id = source_field(source, :legislation_id, 'legislation_id')
      value ||= "FISCONET_#{legislation_id}" if legislation_id
      value.to_s.presence
    end

    def retrieved_source_article_number(source)
      if eurlex_corpus_source?(source)
        record = verified_eurlex_corpus_record(source)
        return unless record && source_field(record, :kind, 'kind') == 'article'

        return normalize_article_number(source_field(record, :unit_number, 'unit_number')).presence
      end

      raw = source_field(source, :article_number, 'article_number', :article, 'article')
      metadata = source_field(source, :metadata, 'metadata')
      raw ||= source_field(metadata, :article_number, 'article_number') if metadata
      title = source_field(source, :article_title, 'article_title')
      raw ||= title.to_s.match(%r{\bArt(?:ikel|icle)?\.?\s*([[:alnum:]][\w/.:-]*)}i)&.[](1)
      raw ||= link_article_number(source_field(source, :url, 'url'))
      normalize_article_number(strip_article_prefix(raw)).presence
    end

    # The source tag is a routing marker, NOT evidence. An EU id remains in
    # this lane even if someone changes its tag to impersonate a domestic or
    # regional source. Its identity/body must match the immutable generation.
    def eurlex_corpus_source?(source)
      source_field(source, :source, 'source') == 'eurlex_corpus' ||
        source_field(source, :eu_chunk_id, 'eu_chunk_id').present?
    end

    def verified_eurlex_corpus_record(source)
      return unless eurlex_corpus_source?(source)
      return unless LegalChatbot::EuCorpus.verified_record?(source)

      # Verification above bound EVERY canonical field to the exact core/live
      # snapshot. Looking up the ID a second time could instead return the
      # older pinned core metadata for a freshly verified cache record. Keep
      # that bound snapshot, stripping all unverified extra source attributes.
      keys = LegalChatbot::EuCorpus::IDENTITY_FIELDS + %i[source article_number]
      keys += [:history_seal] if source_field(source, :historical, 'historical') == true
      keys.select! { |key| source.key?(key) || source.key?(key.to_s) }
      keys.to_h { |key| [key, source_field(source, key, key.to_s)] }
    rescue StandardError => e
      Rails.logger.warn("[EuCorpusGuard] source verification unavailable: #{e.class}")
      nil
    end

    def eurlex_record_names(record)
      (Array(source_field(record, :aliases, 'aliases')) +
        %i[law_title title article_title celex ecli case_number].filter_map do |key|
          source_field(record, key, key.to_s).to_s.presence
        end).uniq
    end

    # A German row (language_id 3) is evidence only as a binding German
    # original that the German lane hydrated (it carries :german_original,
    # whose source_method is binding) on a service that runs the lane
    # (@german_lane, gesetzguide browser requests only) with
    # GERMAN_ORIGINALS_MODE=on. The context builder, QuoteGuard,
    # CitationGuard and LinkGuard all ask this one question, so a German
    # translation, a consolidation or a German row from any other path is
    # never quoted, cited or linked as German law.
    def german_original_source?(source)
      return false unless @german_lane == true && LegalChatbot::GermanArticleSearch.originals_on?
      return false unless german_row_source?(source)

      original = source_field(source, :german_original, 'german_original')
      return false unless original.is_a?(Hash)

      GermanTextProvenance.binding_original?(original[:source_method] || original['source_method'])
    end

    def german_row_source?(source)
      return false if eurlex_corpus_source?(source)

      source_field(source, :language_id, 'language_id').to_i == LegalChatbot::GermanArticleSearch::GERMAN_LANGUAGE_ID
    end

    # [numac, article number] of every retrieved binding German original.
    def german_original_pairs(sources)
      Array(sources).filter_map do |source|
        next unless german_original_source?(source)

        numac = retrieved_source_numac(source)
        number = retrieved_source_article_number(source)
        [numac, number] if numac.present? && number.present?
      end.to_set
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
          rescue IndexError, TypeError, NameError # KeyError < IndexError, NoMethodError < NameError
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
