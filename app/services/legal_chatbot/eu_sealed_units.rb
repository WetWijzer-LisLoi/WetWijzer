# frozen_string_literal: true

require 'digest'

module LegalChatbot
  # Identity check shared by the practical answer checks: an exact EU article
  # of an exact consolidated edition and language, still reader-verified
  # against the corpus it came from, whose complete body is the reviewed one.
  # A changed, excerpted, relabelled or other-edition unit disables the check
  # that depends on it; it never widens what a check accepts.
  module EuSealedUnits
    MAX_SOURCE_CHARS = 20_000
    # Paragraph markers as EUR-Lex prints them: "1. Text" in the Dutch,
    # French and English editions, "(1) Text" in the German one. A marker
    # starts the body or follows whitespace (and a consolidation marker such
    # as "▼B"), and is followed by the paragraph's first word.
    PARAGRAPH_MARKER = /(?:\A|(?<=\s))(?:(\d{1,2})\.|\((\d{1,2})\))\s+(?=[\p{Lu}«„"“(▼])/u
    LINK_PATTERN = /\[([^\]]+)\]\(([^)\s]+)\)/
    # "Artikel 5, lid 4", "art. 21(2)", "Article 17, paragraphe 5",
    # "Artikel 20 Absatz 6", "lid 4 van artikel 5": the paragraph number.
    PARAGRAPH_LABEL_PATTERN = /\A\s*(?:l['’]\s*|(?:het|de|the|le|der|die|des|dem|den)\s+)?(?:art(?:ikel|icle|\.)?\s*)?\d+\s*(?:,\s*)?(?:lid|§|paragraaf|paragraphe|paragraph|Absatz|Abs\.)\s*(\d{1,2})\b|\A\s*(?:l['’]\s*|(?:het|de|the|le|der|die|des|dem|den)\s+)?(?:art(?:ikel|icle|\.)?\s*)?\d+\s*\((\d{1,2})\)|\A\s*(?:(?:het|de|le|the|der)\s+)?(?:lid|paragraaf|paragraphe|paragraph|Absatz)\s*(\d{1,2})\s+(?:van|of|de|du|des|von)\s+(?:het\s+|l['’]\s*|the\s+)?art/iu
    # The same label written just after the link: "[artikel 5](...), lid 4".
    FOLLOWING_PARAGRAPH_PATTERN = /\A\s*,?\s*(?:lid|§|paragraaf|paragraphe|paragraph|Absatz|Abs\.)\s*(\d{1,2})\b|\A\((\d{1,2})\)/iu

    module_function

    # Each markdown link to a sealed article that names a paragraph, in the
    # label or right after the link: number, paragraph and link offsets.
    def paragraph_references(text, grounded)
      text.to_s.to_enum(:scan, LINK_PATTERN).filter_map do
        match = Regexp.last_match
        label, url = match.captures
        number = grounded.keys.find { |key| url == field(grounded[key], :url) }
        next unless number

        paragraph = label.match(PARAGRAPH_LABEL_PATTERN)&.captures&.compact&.first ||
                    match.post_match.match(FOLLOWING_PARAGRAPH_PATTERN)&.captures&.compact&.first
        { number: number, paragraph: paragraph, begin: match.begin(0), end: match.end(0) } if paragraph
      end
    end

    # A valid article link does not make an invented paragraph supported: the
    # sealed article must actually have the paragraph the label names.
    def unsupported_paragraph?(text, grounded)
      paragraph_references(text, grounded).any? do |reference|
        !paragraphs(field(grounded[reference[:number]], :article_text)).key?(reference[:paragraph])
      end
    end

    # number => source, for each sealed article present in this turn's pool.
    def selected(sources, celex:, signatures:)
      Array(sources).each_with_object({}) do |source, selected|
        number = sealed_number(source, celex: celex, signatures: signatures)
        selected[number] ||= source if number
      end
    end

    def sealed_number(source, celex:, signatures:)
      return nil unless source.is_a?(Hash)
      return nil unless field(source, :source) == EuCorpus::SOURCE && field(source, :source_kind) == 'legislation'
      return nil unless field(source, :kind) == 'article' && field(source, :celex) == celex
      return nil unless field(source, :historical) == false && field(source, :retrieval_scope) == 'eligible_source_edition'

      number = field(source, :unit_number).to_s
      language = field(source, :language).to_s
      expected = signatures[[number, language]]
      return nil unless expected
      return nil unless field(source, :article_number).to_s == number && [nil, number].include?(field(source, :unit_identity_number))
      return nil unless field(source, :url) == unit_url(celex, language, number)

      body = field(source, :article_text)
      return nil unless body.is_a?(String) && body.valid_encoding? && body.length <= MAX_SOURCE_CHARS
      return nil unless Digest::SHA256.hexdigest(body) == expected && field(source, :body_sha256) == expected
      return nil unless EuCorpus.verified_record?(source)

      number
    end

    def unit_url(celex, language, number)
      "https://eur-lex.europa.eu/legal-content/#{language.upcase}/TXT/HTML/?uri=CELEX:#{celex}#art_#{number}"
    end

    # { '1' => text, '2' => text, ... } in body order; empty when the body
    # carries no numbered paragraphs at all.
    def paragraphs(body)
      text = body.to_s
      markers = text.enum_for(:scan, PARAGRAPH_MARKER).map { Regexp.last_match }
      numbers = markers.map { |match| (match[1] || match[2]).to_i }
      # A paragraph marker sequence counts upwards from 1. Anything else (a
      # list item, a cross-reference that happens to look like one) is text.
      kept = []
      markers.each_with_index do |match, index|
        kept << match if numbers[index] == kept.length + 1
      end
      kept.each_with_index.to_h do |match, index|
        stop = kept[index + 1]&.begin(0) || text.length
        [match[1] || match[2], text[match.end(0)...stop].strip]
      end
    end

    def field(source, key)
      return source[key] if source.key?(key)

      source[key.to_s]
    end
  end
end
