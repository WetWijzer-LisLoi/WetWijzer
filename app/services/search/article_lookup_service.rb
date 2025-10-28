# frozen_string_literal: true

module Search
  # Instant article lookup by abbreviation pattern.
  # Parses queries like "art 1382 BW", "artikel 5 WVV", "art. 38 WPW"
  # and returns direct article matches from the database.
  #
  # Usage:
  #   Search::ArticleLookupService.new(locale: :nl).lookup("art 1382 BW")
  #   # => [{ title: "Art. 1382", subtitle: "Oud BW Boek III - Verbintenissen/Contracten", url: "/laws/1804032154#..." }]
  class ArticleLookupService
    MAX_RESULTS = 8

    # Regex to match article-reference patterns:
    #   "art 1382 BW", "artikel 5 WVV", "Art. 461bis SW", "art 1 §2 GW"
    # Captures: (1) article number+suffix, (2) law abbreviation
    ARTICLE_PATTERN = /\A\s*art(?:ikel|icle|\.?\s*)[\s.]*(\d+\S*)\s+([a-z0-9\-.]+)\s*\z/i

    # ─── Law Abbreviation → NUMAC mapping ───
    # Keys are downcased. Values are arrays of NUMACs to search across.
    # Covers both NL and FR abbreviations for the same law.
    LAW_ABBREVIATIONS = {
      # ── Burgerlijk Wetboek (Oud + Nieuw) ──
      'bw' => %w[1804032150 1804032151 1804032152 1804032153 1804032154 1804032155 1804032156
                 2022A32057 2022A30600 2020A20347 2022B30600 2022A32058 2024A01600 2019A12168 2025A05089],
      'cc' => %w[1804032150 1804032151 1804032152 1804032153 1804032154 1804032155 1804032156],
      'obw' => %w[1804032150 1804032151 1804032152 1804032153 1804032154 1804032155 1804032156],
      'nbw' => %w[2022A32057 2022A30600 2020A20347 2022B30600 2022A32058 2024A01600 2019A12168 2025A05089],

      # ── Vennootschapsrecht ──
      'wvv' => %w[2019A40586],
      'csa' => %w[2019A40586],

      # ── Strafrecht ──
      'sw' => %w[1867060850],
      'cp' => %w[1867060850],
      'swb' => %w[1867060850],
      'sv' => %w[1808111701],
      'csv' => %w[1808111701],
      'cic' => %w[1808111701],
      'ssw' => %w[2010A09589],

      # ── Grondwet ──
      'gw' => %w[1994021048],
      'const' => %w[1994021048],

      # ── Gerechtelijk Wetboek ──
      'ger.w' => %w[1967101052],
      'ger.w.' => %w[1967101052],
      'gerw' => %w[1967101052],
      'cj' => %w[1967101052],

      # ── Economisch Recht ──
      'wer' => %w[2013A11134],
      'cde' => %w[2013A11134],

      # ── Fiscaal ──
      'wib' => %w[1992003455],
      'wib92' => %w[1992003455],
      'cir' => %w[1992003455],
      'cir92' => %w[1992003455],
      'btw' => %w[1969070305],
      'wbtw' => %w[1969070305],
      'ctva' => %w[1969070305],
      'vcf' => %w[2013036154],

      # ── Arbeidsrecht ──
      'aow' => %w[1978070303],
      'aow78' => %w[1978070303],
      'aw' => %w[1971031602],
      'aw71' => %w[1971031602],

      # ── Woninghuur ──
      'vwd' => %w[2018015087],
      'hhw' => %w[1951043003],

      # ── Codexen ──
      'vcro' => %w[2009A24414],
      'vcw' => %w[2020A43545],
      'bhc' => %w[2013A31614],

      # ── Vreemdelingenrecht ──
      'vw' => %w[1980121550],

      # ── Nationaliteit ──
      'wbn' => %w[1984900065],
      'cnb' => %w[1984900065],

      # ── IPR ──
      'wipr' => %w[2004A10001],
      'cdip' => %w[2004A10001],

      # ── Wegverkeer ──
      'wpw' => %w[1968031601],
      'wvw' => %w[1968031601],
      'wegc' => %w[1975032710],

      # ── Sociaal ──
      'welz' => %w[1996012650],
      'lbw' => %w[1965041207],

      # ── Specifieke wetten ──
      'drugw' => %w[1921022450],
      'eov' => %w[1973100550],
      'cbe' => %w[1973100550],

      # ── Patiëntenrechten / Gezondheidszorg ──
      'wpr' => %w[2002082245],
      'euth' => %w[2002052850],

      # ── Privacyrecht ──
      'avg' => %w[2018040581],
      'gdpr' => %w[2018040581],
      'rgpd' => %w[2018040581],

      # ── Nieuw BW per boek (precise) ──
      'bw1' => %w[2022A32057],
      'bw2' => %w[2022A30600],
      'bw3' => %w[2020A20347],
      'bw4' => %w[2022B30600],
      'bw5' => %w[2022A32058],
      'bw6' => %w[2024A01600],
      'bw8' => %w[2019A12168],
      'bw9' => %w[2025A05089]
    }.freeze

    # Friendly labels for abbreviations (used in result subtitles)
    ABBREVIATION_LABELS = {
      'bw' => 'Burgerlijk Wetboek', 'cc' => 'Code Civil', 'obw' => 'Oud Burgerlijk Wetboek',
      'nbw' => 'Nieuw Burgerlijk Wetboek',
      'wvv' => 'WVV', 'csa' => 'CSA',
      'sw' => 'Strafwetboek', 'cp' => 'Code Pénal', 'sv' => 'Wetboek van Strafvordering',
      'gw' => 'Grondwet', 'const' => 'Constitution',
      'gerw' => 'Gerechtelijk Wetboek', 'ger.w' => 'Gerechtelijk Wetboek', 'ger.w.' => 'Gerechtelijk Wetboek',
      'cj' => 'Code Judiciaire',
      'wer' => 'Wetboek Economisch Recht', 'cde' => 'Code de Droit Économique',
      'wib' => 'WIB92', 'wib92' => 'WIB92', 'cir' => 'CIR92', 'cir92' => 'CIR92',
      'btw' => 'BTW-Wetboek', 'wbtw' => 'BTW-Wetboek', 'ctva' => 'Code TVA',
      'vcf' => 'Vlaamse Codex Fiscaliteit',
      'aow' => 'Arbeidsovereenkomstenwet', 'aw' => 'Arbeidswet',
      'vcro' => 'VCRO', 'wipr' => 'Wetboek IPR',
      'wpw' => 'Wegverkeerswet (WPW)', 'wvw' => 'Wegverkeerswet (WPW)', 'vw' => 'Vreemdelingenwet',
      'avg' => 'AVG/GDPR', 'gdpr' => 'AVG/GDPR'
    }.freeze

    def initialize(locale: :nl)
      @language_id = locale.to_s == 'fr' ? 2 : 1
    end

    # @param query [String] user input, e.g. "art 1382 BW"
    # @return [Array<Hash>] article results with :title, :subtitle, :url, :source
    def lookup(query)
      return [] if query.blank?

      match = query.strip.match(ARTICLE_PATTERN)
      return [] unless match

      article_num = match[1] # e.g. "1382", "5bis", "1 §2"
      abbreviation = match[2].downcase.strip

      numacs = LAW_ABBREVIATIONS[abbreviation]
      return [] unless numacs&.any?

      find_articles(article_num, numacs, abbreviation)
    end

    # Check if a query looks like an article reference (for UI hints)
    def self.article_query?(query)
      query.present? && query.strip.match?(ARTICLE_PATTERN)
    end

    private

    def find_articles(article_num, numacs, abbreviation)
      # Build LIKE patterns: "Art. 1382" or "Art. 1382%" for bis/ter variants
      # The article_title field typically stores "Art. 1", "Art. 1382", "Art. 1382bis"
      like_patterns = [
        "Art. #{article_num}",
        "Art.#{article_num}",
        "Art #{article_num}",
        "Artikel #{article_num}",
        "Article #{article_num}"
      ]

      # Query across all NUMACs for this abbreviation
      articles = Article.where(content_numac: numacs, language_id: @language_id)

      # Try exact match first, then prefix match
      results = articles.where(article_title: like_patterns).limit(MAX_RESULTS)

      if results.empty?
        # Fallback: prefix match (catches "Art. 1382bis", "Art. 1382/1")
        prefix_conditions = like_patterns.map { |_p| 'article_title LIKE ?' }.join(' OR ')
        prefix_values = like_patterns.map { |p| "#{p}%" }
        results = articles.where(prefix_conditions, *prefix_values).limit(MAX_RESULTS)
      end

      results.map do |article|
        law = Legislation.find_by(numac: article.content_numac, language_id: @language_id)
        law_label = ABBREVIATION_LABELS[abbreviation] || law&.title&.truncate(60) || abbreviation.upcase

        {
          title: article.display_title,
          subtitle: law_label,
          url: "/laws/#{article.content_numac}?language_id=#{@language_id}#artikel-#{article_anchor(article)}",
          source: :article
        }
      end
    rescue StandardError => e
      Rails.logger.error("ArticleLookupService#find_articles error: #{e.message}")
      []
    end

    # Build the anchor fragment for deep-linking to the article within the law page
    def article_anchor(article)
      title = article.article_title.to_s.strip
      # Normalize: "Art. 1382" → "1382", "Art. 1382bis" → "1382bis"
      num = title.sub(/\A(?:Art\.?\s*|Artikel\s*|Article\s*)/i, '').strip
      num.presence || article.id.to_s
    end
  end
end
