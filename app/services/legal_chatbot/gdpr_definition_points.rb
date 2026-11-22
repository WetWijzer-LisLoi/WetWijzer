# frozen_string_literal: true

module LegalChatbot
  # #1582 (Sol 2026-11-22 13:14:02Z): GDPR art. 4 gives every definition at one article URL. The controller's is point 7
  # and the processor's point 8, each the art. 4 record of its own pack, which names its `point`. Kept by URL and article
  # number alone, the two points merged: a difference answer that cited only one of them counted as complete, and a
  # controller answer citing point 8 passed. Here the point is read from the label users see ("Art. 4, punt 7",
  # "Art. 4(8)", "Art. 4 Nr. 7 und 8"): a required point is cited only when a label names it, and a label naming a point
  # no source holds at that URL misattributes the text behind the link.
  module GdprDefinitionPoints
    # The points a label names right after the article number: "punt 7", "punten 7 en 8", "point 7", "Nr. 7 und 8",
    # "Nummer 7", "(7) and (8)", "(7) and 4(8)", ", 7)"
    POINT_LIST = /\A[[:space:],]*(?:(?:punt(?:en)?|points?|nrn?\.?|nummern?|ziff(?:ern?|\.)|lid|leden)[[:space:]]*)?
                  (?<list>\(?\d{1,2}\)?(?!\d)(?:[[:space:]]*(?:,|en|et|und|and|&)[[:space:]]*(?:4[[:space:]]*)?\(?\d{1,2}\)?(?!\d))*)/ix
    POINT_ITEM = /(?:(?<!\d)4[[:space:]]*(?=\())?\(?(\d{1,2})\)?/
    LABELS = {
      'nl' => { %w[7] => 'Art. 4, punt 7 — AVG (definitie verwerkingsverantwoordelijke)',
                %w[8] => 'Art. 4, punt 8 — AVG (definitie verwerker)',
                %w[7 8] => 'Art. 4, punten 7 en 8 — AVG (definities)' }.freeze,
      'fr' => { %w[7] => 'Art. 4, point 7 — RGPD (définition du responsable du traitement)',
                %w[8] => 'Art. 4, point 8 — RGPD (définition du sous-traitant)',
                %w[7 8] => 'Art. 4, points 7 et 8 — RGPD (définitions)' }.freeze,
      'de' => { %w[7] => 'Art. 4 Nr. 7 — DSGVO (Begriffsbestimmung des Verantwortlichen)',
                %w[8] => 'Art. 4 Nr. 8 — DSGVO (Begriffsbestimmung des Auftragsverarbeiters)',
                %w[7 8] => 'Art. 4 Nr. 7 und 8 — DSGVO (Begriffsbestimmungen)' }.freeze,
      'en' => { %w[7] => 'Art. 4(7) — GDPR (controller definition)',
                %w[8] => 'Art. 4(8) — GDPR (processor definition)',
                %w[7 8] => 'Art. 4(7) and (8) — GDPR (definitions)' }.freeze
    }.freeze
    ACRONYMS = { 'nl' => 'AVG', 'fr' => 'RGPD', 'de' => 'DSGVO', 'en' => 'GDPR' }.freeze

    module_function

    # [url, article number, point] of every GDPR record that names its point
    def units(sources)
      Array(sources).filter_map do |source|
        next unless source.is_a?(Hash)

        point = field(source, :point).to_s
        next if point.empty? || field(source, :official_source_id) != LegalFactProvider::GDPR_PROCESSOR_OFFICIAL_SOURCE_ID

        [field(source, :url).to_s, field(source, :article_number).to_s, point]
      end.to_set
    end

    # [url, article number, point] for each point a link label names, among links to one of pairs
    def cited(text, pairs, normalize)
      links(text, pairs, normalize).flat_map { |url, number, points| points.map { |point| [url, number, point] } }.to_set
    end

    # [url, article number, point] for each point a label names that no source holds at that link
    def misattributed(text, sources, normalize)
      held = units(sources)
      pairs = held.to_set { |url, number, _point| [url, number] }
      cited(text, pairs, normalize).reject { |unit| held.include?(unit) }.sort
    end

    # [url, article number, named points] for each Markdown link to one of pairs
    def links(text, pairs, normalize)
      return [] if pairs.empty?

      text.to_s.scan(Orchestrator::MARKDOWN_LINK_PATTERN).filter_map do |markdown|
        next if markdown.start_with?('!')

        parsed = markdown.match(%r{\A\[([^\]\n]+)\]\((https?://[^)\n]+)\)\z}i)
        next unless parsed

        label, url = parsed.captures
        found = label.match(Orchestrator::SINGLE_ARTICLE_CITATION_PATTERN)
        next unless found

        number = normalize.call(found[:number])
        [url, number, named_points(label[found.end(0)..])] if pairs.include?([url, number])
      end
    end

    def named_points(rest)
      list = rest.to_s.match(POINT_LIST)
      list ? list[:list].scan(POINT_ITEM).flatten.uniq : []
    end

    # The label of an appended art. 4 link naming points
    def label(points, language)
      language = LABELS.key?(language.to_s) ? language.to_s : 'nl'
      LABELS.fetch(language).fetch(points.uniq.sort) do
        "Art. 4 (#{points.uniq.sort.join(', ')}) — #{ACRONYMS.fetch(language)}"
      end
    end

    def field(source, key)
      source.key?(key) ? source[key] : source[key.to_s]
    end
  end
end
