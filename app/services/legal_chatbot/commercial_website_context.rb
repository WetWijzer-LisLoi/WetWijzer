# frozen_string_literal: true

module LegalChatbot
  # Preserve qualifications in the already-retrieved commercial website pack.
  # These finite, article-specific ceilings are not a general context expansion
  # or a replacement for the current corpus. Oversized or unrecognised records
  # retain the normal excerpt path; no statutory wording is reconstructed.
  module CommercialWebsiteContext
    ARTICLE_CHAR_CEILINGS = {
      ['2013A11134', 'XII.6'] => 2500,
      ['2013A11134', 'XII.7'] => 1500,
      ['2013A11134', 'XII.9'] => 1000,
      ['2013A11134', 'XII.10'] => 1000,
      ['2013A11134', 'III.74'] => 3000,
      ['2013A11134', 'VI.45'] => 12_000,
      ['2013A11134', 'VI.46'] => 7500,
      ['2013A11134', 'VI.47'] => 2500,
      ['2013A11134', 'VI.53'] => 4500,
      ['2013A11134', 'VI.61/1'] => 500,
      ['2013A11134', 'VI.61/2'] => 3000,
      ['2018040581', '10/2'] => 2000
    }.transform_keys(&:freeze).freeze

    def self.excerpt(article, text:, question:)
      return nil unless CommercialWebsiteIntent.topic?(question)
      return nil unless [1, 2].include?(field(article, :language_id))

      title = field(article, :article_title).to_s
      number = title[%r{\A\s*Art(?:ikel|icle)?\.?\s*((?:[IVX]+\.)?\d+(?:/\d+)?)\s*\z}i, 1]
      pair = [field(article, :numac).to_s, number&.upcase]
      ceiling = ARTICLE_CHAR_CEILINGS[pair]
      return nil unless ceiling && CommercialWebsiteIntent.article_targets(question).include?(pair)
      return nil if text.to_s.strip.empty? || text.length > ceiling

      text
    end

    def self.field(article, key)
      article[key] || article[key.to_s]
    end
    private_class_method :field
  end
end
