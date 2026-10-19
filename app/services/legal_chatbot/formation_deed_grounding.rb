# frozen_string_literal: true

module LegalChatbot
  # This is a narrow source-note check, not a verifier of arbitrary legal
  # conclusions. It activates only when the retrieved WVV Article 6:13 itself
  # records the annulment relevant to an explicit cooperative formation deed.
  class FormationDeedGrounding
    NUMAC = '2019A40586'
    VERSION = 2
    MAX_NOTE_CHARS = 1000
    CONDITION_CODES = %w[formation_deed_annulment_qualification formation_deed_annulled_point_as_current].freeze
    ARTICLE_NUMBER_PATTERN = /\A\s*(?:Art(?:ikel|icle)?\.?\s*)?6\s*[:_-]\s*13\.?\s*\z/i
    ARTICLE_REFERENCE_PATTERN = /\b6\s*[:_-]\s*13\b/
    FIRST_PARAGRAPH_PATTERN = /\b(?:eerste\s+lid|(?:1e|1ste)\s+lid|lid\s+1|alin[eé]a\s+(?:1er|1|premier)|premier\s+alin[eé]a|first\s+(?:sub)?paragraph|(?:Abs(?:atz)?\.?\s*1|erste[nrms]?\s+Absatz))\b/i
    POINT_FOUR_PATTERN = /(?:\b4\s*[°º]|\b(?:punt|point|item|number|num[eé]ro|Nr\.?|Nummer)\s*4\b|\b4\s*\))/i
    DIRECT_POINT_FOUR_PATTERN = /#{ARTICLE_REFERENCE_PATTERN.source}\s*(?:(?:WVV|CSA)\s*)?(?:[,.:-]\s*4\s*[°º]|(?:punt|point|item|number|num[eé]ro|Nr\.?|Nummer)\s*4\b)/i
    OTHER_PARAGRAPH_PATTERN = /(?:§\s*(?:[2-9]\d*|1\d+)|\b(?:lid|alin[eé]a|paragraph|Abs(?:atz)?\.?)\s*(?:[2-9]\d*|1\d+)\b|\b(?:deuxi[eè]me|second|zweite[nrms]?)\s+(?:alin[eé]a|paragraph|Absatz)\b)/i
    LOCAL_REFERENCE_GAP = /(?:(?!\b\d+\s*[:_-]\s*\d+\b|[.!?;\n]|#{OTHER_PARAGRAPH_PATTERN.source}).){0,100}/i
    HISTORICAL_PATTERN = /\b(?:historisch(?:e)?|historique|historical)\b/i
    ANNULMENT_PATTERN = /\b(?:vernietigd|vernietiging|nietig\s+verklaard|annul[eé]e?s?|annulation|annulled|annulment|voided|aufgehoben|Aufhebung|Nichtigerkl[aä]rung|nichtig\s+erkl[aä]rt)\b/i
    NEGATED_ANNULMENT_PATTERN = /\b(?:niet|not|pas|nicht)\s+(?:(?:is|was|werd|été|been|wurde)\s+)?#{ANNULMENT_PATTERN.source}/i
    # These source patterns follow the supplied NL/FR note, rather than
    # manufacturing an annulment from an unrelated date or legal citation.
    SOURCE_ANNULMENT_PATTERN = /(?:eerste\s+lid,\s*4°[\s\S]{0,400}\bvernietigd\b|annul[eé]\s+l['’]alin[eé]a\s+1er,\s*4°)/i

    class << self
      def topic?(question)
        normalized = question.to_s.gsub(/[[:space:]]+/, ' ')
        normalized.match?(LegislationSearch::FORMATION_DEED_PATTERN) &&
          LegislationSearch.formation_deed_entity_context?(normalized) &&
          LegislationSearch.formation_deed_explicit_form(normalized) == :cv
      end

      def evidence(sources)
        Array(sources).each do |source|
          next unless field(source, :numac).to_s == NUMAC
          next unless (field(source, :article_number).presence || field(source, :article_title)).to_s.match?(ARTICLE_NUMBER_PATTERN)
          next unless canonical_anchor?(source)

          language_id = field(source, :language_id)
          next unless language_id.is_a?(Integer) && [1, 2].include?(language_id)

          text = field(source, :article_text, :text, :full_text, :content).to_s
          note = text[/\((?:NOTA|NOTE)\s*:[\s\S]*\)\s*\z/i]&.strip
          next unless note && note.length <= MAX_NOTE_CHARS && note.match?(SOURCE_ANNULMENT_PATTERN)
          next if note.match?(NEGATED_ANNULMENT_PATTERN)

          return { source: source, note: note }
        end
        nil
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) && evidence(sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded

        # Inspect visible words, not a hidden URL containing the right anchor.
        visible = answer.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1')
        # Emphasis is presentation, not a word boundary that can conceal
        # negation ("not **annulled**" must stay negative).
        visible = visible.gsub(/(\*{1,3}|_{1,3})(?=\S)(.+?)(?<=\S)\1/m, '\\2')
        annotated_visible = visible
        visible = visible.gsub(/^[ \t]*>[ \t]?/, '')
        note = grounded.fetch(:note)
        missing = []
        missing << CONDITION_CODES.first unless annulment_qualification?(visible, note)
        # An end-of-answer warning must not license an earlier mandatory-list
        # entry or quotation of this specific annulled point. Keep the test
        # local to explicit references, not every mention of shares or 6:13.
        unqualified_point = unqualified_point_reference?(annotated_visible, note)
        missing << CONDITION_CODES.last if unqualified_point
        { applicable: true, missing_conditions: missing, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        codes = Array(missing_conditions).map(&:to_s) & CONDITION_CODES
        return nil if codes.empty?

        FEEDBACK_COPY.fetch(language.to_s, FEEDBACK_COPY.fetch('nl'))
      end

      def fallback(question, sources, language: 'nl')
        grounded = topic?(question) && evidence(sources)
        return nil unless grounded

        copy = FALLBACK_COPY.fetch(language.to_s, FALLBACK_COPY.fetch('nl'))
        # Keep the actual note verbatim in its retrieved language. This is
        # not a reconstructed checklist or a translated statutory quotation.
        quoted_note = grounded.fetch(:note).lines.map { |line| "> #{line.chomp}" }.join("\n")
        [copy.fetch(:heading), copy.fetch(:intro), "#{quoted_note}\n> — [Art. 6:13](/laws/#{NUMAC}#art-6-13)"].join("\n\n")
      end

      private

      def unqualified_point_reference?(visible, note)
        # Preserve positions while removing quote markers and protecting the
        # source's exact note (whose own internal punctuation is not prose).
        plain = visible.gsub(/^[ \t]*>[ \t]?/) { |prefix| prefix.tr('>', ' ') }
        note_pattern = Regexp.new(note.split(/[[:space:]]+/).map { |word| Regexp.escape(word) }.join('[[:space:]]+'))
        note_ranges = []
        plain.scan(note_pattern) { note_ranges << (Regexp.last_match.begin(0)...Regexp.last_match.end(0)) }
        scanned = clause_scan_text(plain)
        note_ranges.each { |range| scanned[range] = scanned[range].gsub(/[^\n]/, ' ') }

        scanned.to_enum(:scan, /[^.!?;\n]+/).any? do
          match = Regexp.last_match
          clause = match[0]
          next false unless explicit_point_four_reference?(clause)

          original_clause = plain[match.begin(0)...match.end(0)]
          next false if annulment_qualification?(original_clause, note, require_first_paragraph: false)

          !preceding_note_qualifies_historical_line?(visible, plain, match.begin(0), note, note_ranges)
        end
      end

      def clause_scan_text(text)
        # Keep character offsets intact. Art./Nr. and the explicit dotted
        # citation 6:13.4° are not sentence boundaries.
        text = text.gsub(/\b(?:Art(?:ikel|icle)?|Abs(?:atz)?|Nr)\./i) { |abbreviation| abbreviation.tr('.', ' ') }
        text.gsub(/(#{ARTICLE_REFERENCE_PATTERN.source})\s*\.\s*(?=4\s*[°º])/) { |reference| reference.tr('.', ',') }
      end

      def preceding_note_qualifies_historical_line?(visible, plain, offset, note, note_ranges)
        line_start = (visible.rindex("\n", [offset - 1, 0].max) || -1) + 1
        line_end = visible.index("\n", offset) || visible.length
        line = visible[line_start...line_end]
        return false unless line.match?(/\A[ \t]*>/) || line.match?(HISTORICAL_PATTERN)

        preceding = note_ranges.rfind { |range| range.end <= line_start }
        return false unless preceding

        between = plain[preceding.end...line_start]
        return false if between.length > 200 || between.match?(/\n[ \t]*\n/) || between.match?(/\S/)

        # A source note may qualify an immediately following historical quote,
        # never an earlier requirement. Include only its nearby attribution.
        start = [preceding.begin - 200, 0].max
        source_note_qualification?(plain[start...line_end], note)
      end

      def annulment_qualification?(visible, note, require_first_paragraph: true)
        prose = visible.gsub(/\b(?:Art(?:ikel|icle)?|Abs(?:atz)?|Nr)\./i) { |abbreviation| abbreviation.tr('.', ' ') }
        prose = prose.gsub(/(#{ARTICLE_REFERENCE_PATTERN.source})\s*\.\s*(?=4\s*[°º])/, '\\1, ')
        qualified = prose.split(/[.!?;\n]+/).any? do |clause|
          point_identified = if require_first_paragraph
                               first_paragraph_point_four?(clause)
                             else
                               explicit_point_four_reference?(clause)
                             end
          clause.length <= 600 && !clause.match?(/\((?:NOTA|NOTE)\s*:/i) && clause.match?(ARTICLE_REFERENCE_PATTERN) &&
            point_identified && clause.match?(ANNULMENT_PATTERN) && !clause.match?(NEGATED_ANNULMENT_PATTERN)
        end
        qualified || source_note_qualification?(visible, note)
      end

      def explicit_point_four_reference?(paragraph)
        text = paragraph.to_s
        explicit_first = text.match?(/#{ARTICLE_REFERENCE_PATTERN.source}#{LOCAL_REFERENCE_GAP.source}#{FIRST_PARAGRAPH_PATTERN.source}#{LOCAL_REFERENCE_GAP.source}#{POINT_FOUR_PATTERN.source}/i) ||
                         text.match?(/#{FIRST_PARAGRAPH_PATTERN.source}#{LOCAL_REFERENCE_GAP.source}#{POINT_FOUR_PATTERN.source}#{LOCAL_REFERENCE_GAP.source}#{ARTICLE_REFERENCE_PATTERN.source}/i)
        return true if explicit_first

        # This direct shape allows no intervening §2/lid2 qualifier. A later
        # paragraph reference belonging to another article cannot suppress it.
        text.match?(DIRECT_POINT_FOUR_PATTERN)
      end

      def first_paragraph_point_four?(clause)
        clause.match?(/#{FIRST_PARAGRAPH_PATTERN.source}[\s\S]{0,100}#{POINT_FOUR_PATTERN.source}/i) ||
          clause.match?(/#{POINT_FOUR_PATTERN.source}[\s\S]{0,100}#{FIRST_PARAGRAPH_PATTERN.source}/i)
      end

      def source_note_qualification?(visible, note)
        normalized_note = note.gsub(/[[:space:]]+/, ' ')
        visible.split(/\n{2,}/).any? do |paragraph|
          paragraph = paragraph.gsub(/[[:space:]]+/, ' ')
          note_index = paragraph.index(normalized_note)
          next false unless note_index

          # The exact note can contain periods in court-number abbreviations.
          # Only its nearby visible attribution qualifies it, not a distant
          # article heading, another note, or a hidden citation URL.
          start = [note_index - 200, 0].max
          length = note_index - start + normalized_note.length + 200
          paragraph[start, length].match?(ARTICLE_REFERENCE_PATTERN)
        end
      end

      def canonical_anchor?(source)
        anchor = field(source, :article_anchor, :anchor)
        return false if anchor.present? && anchor.to_s != '#art-6-13'

        link = field(source, :link, :url)
        link.blank? || link.to_s.match?(%r{\A(?:https://(?:wetwijzer|lisloi|gesetzguide|lexlibera)\.be)?/laws/#{NUMAC}(?:\?language_id=[12])?#art-6-13\z})
      end

      def field(source, *keys)
        keys.each do |key|
          if source.is_a?(Hash)
            [key, key.to_s].each do |candidate|
              value = source[candidate]
              return value unless value.nil?
            end
          elsif source.respond_to?(key)
            value = source.public_send(key)
            return value unless value.nil?
          end
        end
        nil
      end
    end

    FEEDBACK_COPY = {
      'nl' => 'CORRECTIE: lees de werkelijke NOTA/NOTE bij het meegeleverde artikel 6:13. ' \
              'Benoem uitdrukkelijk de daarin opgenomen vernietiging van het eerste lid, 4°, en citeer de meegeleverde bronlink van artikel 6:13. ' \
              'Presenteer of citeer dat vernietigde punt niet als een momenteel geldende eis. ' \
              'Verwijder dat punt uit de lijst met huidige vereisten of label de passage ter plaatse als historisch en vernietigd. Een waarschuwing achteraf volstaat niet. ' \
              'Behoud een letterlijk citaat in de oorspronkelijke brontaal; verzin geen ontbrekende bron of juridische regel. ' \
              'Schrijf het antwoord opnieuw zonder deze correctie of de afgewezen poging te noemen.',
      'fr' => 'CORRECTION : lisez la NOTA/NOTE réelle de l’article 6:13 fourni. ' \
              'Mentionnez expressément l’annulation de l’alinéa 1er, 4°, qui y figure, et citez le lien fourni de l’article 6:13. ' \
              'Ne présentez ni ne citez ce point annulé comme une exigence actuellement applicable. ' \
              'Retirez ce point de la liste des exigences actuelles ou indiquez directement que le passage est historique et annulé. Un avertissement ajouté à la fin ne suffit pas. ' \
              'Gardez toute citation littérale dans la langue originale de la source ; n’inventez aucune source ni règle manquante. ' \
              'Réécrivez la réponse sans mentionner cette correction ni la tentative rejetée.',
      'de' => 'KORREKTUR: lesen Sie die tatsächlich bereitgestellte NOTA/NOTE zu Artikel 6:13. ' \
              'Benennen Sie ausdrücklich die dort angegebene Aufhebung von Absatz 1, Nummer 4, und zitieren Sie den bereitgestellten Quellenlink zu Artikel 6:13. ' \
              'Stellen Sie diesen aufgehobenen Punkt nicht als derzeit geltende Anforderung dar und zitieren Sie ihn nicht als solche. ' \
              'Entfernen Sie diesen Punkt aus der Liste aktueller Anforderungen oder kennzeichnen Sie die Passage unmittelbar als historisch und aufgehoben. Ein späterer Warnhinweis genügt nicht. ' \
              'Belassen Sie wörtliche Zitate in der Originalsprache; erfinden Sie keine fehlende Quelle oder Rechtsregel. ' \
              'Schreiben Sie die Antwort neu, ohne diese Korrektur oder den abgelehnten Versuch zu erwähnen.',
      'en' => 'CORRECTION: read the actual supplied NOTA/NOTE for Article 6:13. ' \
              'Explicitly identify its recorded annulment of the first paragraph, point 4, and cite the supplied Article 6:13 source link. ' \
              'Do not present or quote that annulled point as a currently applicable requirement. ' \
              'Remove that point from the current-requirements checklist or label the passage locally as historical and annulled. A warning appended at the end is not sufficient. ' \
              'Keep verbatim quotations in the original source language; do not invent a missing source or legal rule. ' \
              'Rewrite the answer without mentioning this correction or the rejected attempt.'
    }.freeze

    FALLBACK_COPY = {
      'nl' => {
        heading: '**Geverifieerde bronnota bij artikel 6:13:**',
        intro: 'Het gegenereerde overzicht van de vereisten voor de oprichtingsakte kon niet volledig worden geverifieerd. ' \
               'Het daadwerkelijk geraadpleegde artikel 6:13 bevat de onderstaande vernietigingsnota. Neem deze nota mee bij het lezen van die bepaling.'
      },
      'fr' => {
        heading: '**Note vérifiée de l’article 6:13 :**',
        intro: 'La liste générée des exigences de l’acte constitutif n’a pas pu être entièrement vérifiée. ' \
               'L’article 6:13 effectivement consulté contient la note d’annulation ci-dessous. Tenez compte de cette note à la lecture de cette disposition.'
      },
      'de' => {
        heading: '**Geprüfter Quellenhinweis zu Artikel 6:13:**',
        intro: 'Die erzeugte Übersicht der Anforderungen an die Gründungsurkunde konnte nicht vollständig verifiziert werden. ' \
               'Der tatsächlich konsultierte Artikel 6:13 enthält den folgenden Aufhebungshinweis. Berücksichtigen Sie diesen Hinweis beim Lesen der Bestimmung.'
      },
      'en' => {
        heading: '**Verified source note for Article 6:13:**',
        intro: 'The generated checklist of formation-deed requirements could not be fully verified. ' \
               'The Article 6:13 actually consulted contains the annulment note below. Take this note into account when reading that provision.'
      }
    }.transform_values(&:freeze).freeze
  end
end
