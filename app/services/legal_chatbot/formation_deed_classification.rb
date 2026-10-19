# frozen_string_literal: true

module LegalChatbot
  # Checks only explicit numbered references against a retrieved allocation
  # sentence. It does not verify a checklist's unnumbered legal conclusions.
  class FormationDeedClassification
    NUMAC = '2019A40586'
    VERSION = 2
    CONDITION_CODES = %w[missing_formation_deed_classification].freeze
    FORM_ARTICLES = { bv: '5:12', cv: '6:13', nv: '7:14' }.freeze
    MAX_SOURCE_CHARS = 30_000
    MAX_SELECTION_CHARS = 1400
    STATUTES_PATTERN = /\b(?:statuten|statutair(?:e)?\s+(?:deel|gedeelte|bepalingen)|statuts|partie\s+statutaire|Satzung(?:en|steil)?|articles\s+of\s+association|statutory\s+part)\b/i
    OTHER_PATTERN = /\b(?:(?:andere|overige)\s+(?:bepalingen|gegevens|vermeldingen)(?:\s+van\s+de\s+(?:oprichtings)?akte)?|autres\s+dispositions|other\s+(?:provisions|part)\s+of\s+the\s+(?:formation\s+)?deed|sonstige\s+Bestimmungen\s+der\s+Gründungsurkunde)\b/i
    NEGATED_STATUTES_PATTERN = /(?:niet\s+(?:noodzakelijk|verplicht|vereist|in)|hoef(?:t|en)\s+niet|pas\s+(?:n[ée]cessairement|obligatoirement|dans)|ne\s+[\s\S]{0,35}?pas|not\s+(?:necessarily|required|in)|need\s+not|nicht\s+(?:notwendig|erforderlich|in))[\s\S]{0,70}?#{STATUTES_PATTERN.source}/i
    POSITIVE_STATUTES_PATTERN = /(?:\b(?:moet(?:en)?|verplicht|vereist|doit|doivent|obligatoire|must|required|muss|müssen|erforderlich)\b[\s\S]{0,80}?#{STATUTES_PATTERN.source}|#{STATUTES_PATTERN.source}[\s\S]{0,80}?\b(?:moet(?:en)?|verplicht|vereist|doit|doivent|obligatoire|must|required|muss|müssen|erforderlich)\b)/i
    OPTIONAL_STATUTES_PATTERN = /(?:\b(?:mag|kan|mogen|kunnen)\b[\s\S]{0,60}?#{STATUTES_PATTERN.source}|\b(?:optioneel|facultativement|optionally|optional|freiwillig)\b[\s\S]{0,60}?#{STATUTES_PATTERN.source}|#{STATUTES_PATTERN.source}[\s\S]{0,60}?\b(?:optioneel|facultativement|optionally|optional|freiwillig)\b)/i
    OPTIONAL_PATTERN = /\b(?:optioneel|facultativement|optionally|optional|freiwillig)\b/i
    GENERIC_DEED_SCOPE_PATTERN = /(?:niet\s+beperkt\s+tot|not\s+limited\s+to|pas\s+limit[ée]e?s?\s+aux|nicht\s+beschränkt\s+auf)[\s\S]{0,40}?#{STATUTES_PATTERN.source}/i
    POINT_TOKEN = /\A\s*(\d{1,2})\s*[°º](?:\s*,?\s*([a-z])\))?/i
    LIST_SEPARATOR = /\A\s*(?:,\s*(?:(?:en|et|and|und)\s+)?|(?:en|et|and|und)\s+)/i
    RANGE_SEPARATOR = /\A\s*(?:tot(?:\s+en\s+met)?|à|bis|to|[-–—])\s*/i
    PARAGRAPH_PATTERN = /\A\s*,?\s*(?:§\s*(\d+)|(?:lid|alin[ée]a|paragraph|Abs(?:atz)?\.?)\s*(\d+)(?:er)?)/i
    SELECTION_PATTERNS = {
      1 => {
        statutes: /Voor\s+de\s+vennootschappen\s+waarvoor\s+zij\s+gelden,\s*worden\s+de\s+gegevens\s+vermeld\s+onder\s+artikel\s+2:8,\s*§\s*2,\s*(?<points>[^.]{1,#{MAX_SELECTION_CHARS}}?),\s*opgenomen\s+in\s+de\s+statuten\s+van\s+de\s+vennootschap\./i,
        other: /De\s+gegevens\s+vermeld\s+onder\s+artikel\s+2:8,\s*§\s*2,\s*(?<points>[^.]{1,#{MAX_SELECTION_CHARS}}?),\s*worden\s+opgenomen\s+in\s+de\s+andere\s+bepalingen\s+van\s+de\s+oprichtingsakte\./i,
        form: /De\s+gegevens\s+bedoeld\s+onder\s+(?<points>[^.]{1,#{MAX_SELECTION_CHARS}}?)\s*,?\s*moeten\s+worden\s+opgenomen\s+in\s+het\s+deel\s+van\s+de\s+akte\s+dat\s+de\s+statuten\s+bevat\./i
      },
      2 => {
        statutes: /Pour\s+les\s+sociétés\s+auxquelles\s+elles\s+s['’]appliquent,\s*les\s+données\s+mentionnées\s+à\s+l['’]article\s+2:8,\s*§\s*2,\s*(?<points>[^.]{1,#{MAX_SELECTION_CHARS}}?),\s*sont\s+reprises\s+dans\s+les\s+statuts\s+de\s+la\s+société\./i,
        other: /Les\s+données\s+mentionnées\s+à\s+l['’]article\s+2:8,\s*§\s*2,\s*(?<points>[^.]{1,#{MAX_SELECTION_CHARS}}?),\s*peuvent\s+être\s+reprises\s+dans\s+les\s+autres\s+dispositions\s+de\s+l['’]acte\s+constitutif\./i,
        form: /Les\s+données\s+visées\s+aux\s+(?<points>[^.]{1,#{MAX_SELECTION_CHARS}}?)\s+(?:figurent\s+dans|doivent\s+être\s+reprises\s+dans)\s+la\s+partie\s+de\s+l['’]acte\s+qui\s+contient\s+les\s+statuts\./i
      }
    }.transform_values(&:freeze).freeze

    class << self
      def topic_form(question)
        normalized = question.to_s.gsub(/[[:space:]]+/, ' ')
        return nil unless normalized.match?(LegislationSearch::FORMATION_DEED_PATTERN)
        return nil unless LegislationSearch.formation_deed_entity_context?(normalized)

        form = LegislationSearch.formation_deed_explicit_form(normalized)
        form if FORM_ARTICLES.key?(form)
      end

      def evidence(question, sources)
        form = topic_form(question)
        return nil unless form

        [1, 2].each do |language_id|
          common = canonical_source(sources, '2:5', language_id)
          specific = canonical_source(sources, FORM_ARTICLES.fetch(form), language_id)
          next unless common && specific

          patterns = SELECTION_PATTERNS.fetch(language_id)
          selections = { statutes: selection(common, patterns.fetch(:statutes)),
                         other: selection(common, patterns.fetch(:other)),
                         form: selection(specific, patterns.fetch(:form)) }
          next if selections.values.any?(&:nil?)
          next if selections.fetch(:statutes).fetch(:points).intersect?(selections.fetch(:other).fetch(:points))

          note = form == :cv ? FormationDeedGrounding.evidence([specific]) : nil
          next if form == :cv && !note

          # The source's actual note removes this annulled point from the
          # current mandatory subset; the separate note guard handles claims
          # presenting it as a current requirement.
          mandatory = selections.fetch(:form).fetch(:points)
          mandatory = mandatory.reject { |point| point == [4, nil] } if note
          return { form: form, language_id: language_id, common_source: common, form_source: specific,
                   reference_source: canonical_source(sources, '2:8', language_id),
                   selections: selections, form_mandatory: mandatory, note: note }
        end
        nil
      end

      def evaluate(answer, question, sources)
        grounded = evidence(question, sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded

        missing = misclassified_reference?(answer, grounded) ? CONDITION_CODES.dup : []
        { applicable: true, missing_conditions: missing, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        return nil unless Array(missing_conditions).map(&:to_s).intersect?(CONDITION_CODES)

        FEEDBACK_COPY.fetch(language.to_s, FEEDBACK_COPY.fetch('nl'))
      end

      def context_notice(question, sources, language: 'nl')
        grounded = evidence(question, sources)
        return nil unless grounded && canonical_source(sources, '2:8', grounded.fetch(:language_id))

        parts = [NOTICE_COPY.fetch(language.to_s, NOTICE_COPY.fetch('nl'))]
        # A CV quote must never omit the actual note attached to its point 4.
        parts << note_quote(grounded) if grounded.fetch(:note)
        parts.concat(selection_quotes(grounded))
        parts.join("\n\n")
      end

      def fallback(question, sources, language: 'nl')
        grounded = evidence(question, sources)
        return nil unless grounded && canonical_source(sources, '2:8', grounded.fetch(:language_id))

        parts = [FALLBACK_COPY.fetch(language.to_s, FALLBACK_COPY.fetch('nl'))]
        parts << FormationDeedGrounding.fallback(question, sources, language: language) if grounded.fetch(:note)
        parts.concat(selection_quotes(grounded))
        parts.join("\n\n")
      end

      private

      def canonical_source(sources, article, language_id)
        Array(sources).find do |source|
          next false unless field(source, :numac).to_s == NUMAC && field(source, :language_id) == language_id
          next false unless field(source, :language_id).is_a?(Integer)

          title = field(source, :article_number).presence || field(source, :article_title)
          next false unless title.to_s.match?(/\A\s*(?:Art(?:ikel|icle)?\.?\s*)?#{Regexp.escape(article)}\.?\s*\z/i)
          next false unless canonical_anchor?(source, article)
          next false if field(source, :truncated, :is_truncated) == true

          text = source_text(source)
          text.present? && text.length <= MAX_SOURCE_CHARS && !text.match?(/(?:\.\.\.|…)\s*\z/)
        end
      end

      def canonical_anchor?(source, article)
        anchor = "#art-#{article.tr(':', '-')}"
        supplied_anchor = field(source, :article_anchor, :anchor)
        return false if supplied_anchor.present? && supplied_anchor.to_s != anchor

        link = field(source, :link, :url)
        return true if link.blank?

        match = link.to_s.match(%r{\A(?:https://(?:wetwijzer|lisloi|gesetzguide|lexlibera)\.be)?/laws/#{NUMAC}(?:\?language_id=([12]))?#{Regexp.escape(anchor)}\z})
        match && (!match[1] || match[1].to_i == field(source, :language_id))
      end

      def source_text(source)
        field(source, :article_text, :text, :full_text, :content).to_s
      end

      def selection(source, pattern)
        matches = source_text(source).to_enum(:scan, pattern).map { Regexp.last_match.dup }
        return nil unless matches.length == 1

        match = matches.first
        return nil if match[0].length > MAX_SELECTION_CHARS

        parsed = parse_points(match[:points], strict: true)
        return nil unless parsed&.fetch(:points)&.any?

        { text: match[0], points: parsed.fetch(:points) }
      end

      # Parse only explicit ordinals, optionally with subletters, and bounded
      # inclusive ranges. Justel amendment markers are presentation metadata.
      def parse_points(text, strict: false)
        input = text.to_s.gsub(/\[\d+\s+([^\]]+)\]\d+[°º]?/, '\\1')
        remaining = input
        points = []
        previous = nil
        consumed = 0
        loop do
          token = POINT_TOKEN.match(remaining)
          subletter = !token && previous && /\A\s*([a-z])\)/i.match(remaining)
          break unless token || subletter

          point = token ? [token[1].to_i, token[2]&.downcase] : [previous[0], subletter[1].downcase]
          return nil unless point[0].between?(1, 99)

          token_length = (token || subletter)[0].length
          remaining = remaining[token_length..]
          consumed += token_length
          points << point
          previous = point
          range = RANGE_SEPARATOR.match(remaining)
          if range
            ending = POINT_TOKEN.match(remaining[range[0].length..])
            return nil unless ending && point[1].nil? && ending[2].nil?

            last = ending[1].to_i
            return nil unless last >= point[0] && last - point[0] <= 30

            points.concat(((point[0] + 1)..last).map { |number| [number, nil] })
            consumed += range[0].length + ending[0].length
            remaining = remaining[(range[0].length + ending[0].length)..]
            previous = [last, nil]
          end
          separator = LIST_SEPARATOR.match(remaining)
          break unless separator

          after = remaining[separator[0].length..]
          break unless after.match?(POINT_TOKEN) || after.match?(/\A\s*[a-z]\)/i)

          consumed += separator[0].length
          remaining = after
        end
        return nil if points.empty? || (strict && !remaining.match?(/\A\s*,?\s*\z/))

        # A bare point 15 cannot prove that the explicitly selected subletters
        # a/b apply; do not widen those subletters to every part of that point.
        points.reject! { |point| point[1].nil? && points.any? { |other| other[0] == point[0] && other[1] } }
        { points: points.uniq, consumed: consumed }
      end

      def visible_answer(answer)
        visible = answer.to_s.gsub(/\[([^\]]+)\]\(([^)]+)\)/) do
          label = Regexp.last_match(1)
          url = Regexp.last_match(2)
          law = url.match(%r{/laws/([^/#?]+)})
          law && law[1] != NUMAC ? ' ' * label.length : label
        end
        visible.gsub(/(\*{1,3}|_{1,3})(?=\S)(.+?)(?<=\S)\1/m, '\\2')
      end

      def misclassified_reference?(answer, grounded)
        heading_class = nil
        heading_categories = {}
        markdown_section_class = nil
        article_context = nil
        answer.to_s.lines.zip(visible_answer(answer).lines).any? do |original, line|
          if heading?(original, line)
            depth = original[/\A\s*(\#{1,6})\s+/, 1]&.length
            numbered_item = numbered_heading?(original)
            generic_scope = line.match?(GENERIC_DEED_SCOPE_PATTERN)
            inherited = if generic_scope
                          nil
                        elsif numbered_item
                          markdown_section_class
                        elsif depth
                          heading_categories.select { |level, _category| level < depth }.max_by(&:first)&.last
                        else
                          heading_class
                        end
            heading_categories.reject! { |level, _category| level >= depth } if depth
            article_context = article_heading_context(original, line, grounded)
            heading_class = classification(line, heading: true)
            # A numbered bold item inside an explicitly classified Markdown
            # section is still a member of that section. Its descriptive label
            # must not discard placement before a separately quoted attribution.
            # Standalone numbered sections retain their existing reset behavior.
            heading_class ||= inherited if article_context || numbered_item
            if depth
              heading_categories[depth] = heading_class
              markdown_section_class = heading_class
            else
              # Plain/bold section labels have no trustworthy nesting depth.
              # Replace the context instead of recovering an older section.
              heading_categories = { 0 => heading_class }
              if numbered_item
                markdown_section_class = heading_class if markdown_section_class
              elsif !heading_class || heading_class != markdown_section_class
                markdown_section_class = nil
              end
            end
            markdown_section_class = nil if generic_scope
          end
          scan = line.gsub(/\b(?:Art(?:ikel|icle)?|Abs(?:atz)?)\./i) { |word| word.tr('.', ' ') }
          scan = scan.gsub(/(\d+[:_-]\d+)\s*\.(?=\s*\d+\s*[°º])/, '\\1,')
          bound = bound_list_reference(scan, article_context, placement: :trailing)
          next true if bound && classified_reference_wrong?(bound, heading_class, grounded)

          scan.split(/[.!?;]+/).any? do |clause|
            explicit = references(clause, grounded)
            leading = bound_list_reference(clause, article_context)
            explicit << leading if leading
            explicit.any? { |reference| classified_reference_wrong?(reference, heading_class, grounded) }
          end
        end
      end

      def classified_reference_wrong?(reference, heading_class, grounded)
        local = reference.fetch(:text)
        prefix = reference.fetch(:prefix)
        placement = "#{prefix} #{local}"
        optional = placement.match?(OPTIONAL_STATUTES_PATTERN) || (heading_class == :statutes && placement.match?(OPTIONAL_PATTERN))
        local_class = if optional && !placement.match?(POSITIVE_STATUTES_PATTERN)
                        :other
                      else
                        classification(local) || classification(prefix) || heading_class
                      end
        local_class && wrong_classification?(reference, local_class, grounded)
      end

      def heading?(original, line)
        original.match?(/\A\s*\#{1,6}\s+/) || numbered_heading?(original) ||
          original.match?(/\A\s*(?:\*\*|__)[^\n]+(?:\*\*|__)\s*:?\s*\z/) ||
          (line.strip.end_with?(':') && !line.match?(/\A\s*[-+*>]\s+/) &&
            (!line.match?(/\d+\s*[°º]/) || original.match?(/\b\d+\s*:\s*\d+\b/)))
      end

      def numbered_heading?(original)
        original.match?(/\A\s*\d+[.)]\s+(?:\*\*|__)[^\n]+(?:\*\*|__)\s*:?\s*\z/)
      end

      def article_heading_context(original, line, grounded)
        articles = (line.scan(/\b\d+\s*:\s*\d+\b/) + original.scan(/\b\d+\s*:\s*\d+\b/))
                   .map { |article| article.delete(' ') }.uniq
        return nil unless articles.one?

        article = articles.first
        return nil unless ['2:8', FORM_ARTICLES.fetch(grounded.fetch(:form))].include?(article)
        return nil if article == '2:8' && !grounded.fetch(:reference_source)

        # A link's visible label cannot borrow an unrelated law or anchor.
        original.scan(/\[([^\]]+)\]\(([^)]+)\)/).each do |label, url|
          next unless label.match?(/\b#{Regexp.escape(article)}\b/)

          identity = { numac: NUMAC, article_title: article, language_id: grounded.fetch(:language_id), link: url }
          return nil unless canonical_anchor?(identity, article)
        end
        tail = line.split(/\b#{Regexp.escape(article)}\b/, 2).last
        paragraph = PARAGRAPH_PATTERN.match(tail)
        number = paragraph && (paragraph[1] || paragraph[2]).to_i
        return nil if article == '2:8' ? number != 2 : number && number != 1

        { article: article }
      end

      def bound_list_reference(clause, article_context, placement: :leading)
        return nil unless article_context
        return nil if clause.match?(/\b\d+\s*:\s*\d+\b/)

        bullet = /\A[ \t]*(?:[-+*>][ \t]+)+/.match(clause)
        return nil unless bullet

        body = clause[bullet[0].length..].sub(/[.!?;]\s*\z/, '')
        parsed = parse_points(body)
        if placement == :trailing
          # Leading ordinals belong to their own clause. Only a trailing
          # parenthesized ordinal needs inspection across descriptive prose.
          return nil if parsed

          trailing = /\((?<points>[^\n(]{1,180})\)\s*\z/.match(body)
          parsed = parse_points(trailing[:points], strict: true) if trailing
        end
        return nil unless parsed

        { article: article_context.fetch(:article), points: parsed.fetch(:points), text: clause, prefix: '' }
      end

      def classification(text, heading: false)
        return nil if text.match?(GENERIC_DEED_SCOPE_PATTERN)
        return :other if text.match?(NEGATED_STATUTES_PATTERN) || text.match?(OTHER_PATTERN)
        return :statutes if text.match?(heading ? STATUTES_PATTERN : POSITIVE_STATUTES_PATTERN)

        nil
      end

      def references(clause, grounded)
        article_pattern = /\b(2\s*:\s*8|#{Regexp.escape(FORM_ARTICLES.fetch(grounded.fetch(:form)))})\b/
        matches = clause.to_enum(:scan, article_pattern).map { Regexp.last_match.dup }
        matches.filter_map.with_index do |match, index|
          article = match[1].delete(' ')
          ending = matches[index + 1]&.begin(0) || clause.length
          tail = clause[match.end(0)...ending]
          paragraph = PARAGRAPH_PATTERN.match(tail)
          number = paragraph && (paragraph[1] || paragraph[2]).to_i
          next if article == '2:8' ? number != 2 : number && number != 1

          tail = tail[paragraph[0].length..] if paragraph
          tail = tail.sub(/\A\s*(?:WVV|CSA)?\s*[,.:]?\s*/i, '')
          parsed = parse_points(tail)
          next unless parsed

          { article: article, points: parsed.fetch(:points), text: clause[match.begin(0)...ending],
            prefix: clause[0...matches.first.begin(0)] }
        end
      end

      def wrong_classification?(reference, category, grounded)
        points = reference.fetch(:points)
        if reference.fetch(:article) == '2:8'
          opposite = category == :statutes ? :other : :statutes
          points.intersect?(grounded.fetch(:selections).fetch(opposite).fetch(:points))
        else
          # These selections require a subset in statutes. They do not forbid
          # putting the remaining deed information in statutes as well.
          category == :other && points.intersect?(grounded.fetch(:form_mandatory))
        end
      end

      def selection_quotes(grounded)
        selections = grounded.fetch(:selections)
        [[selections.fetch(:statutes), '2:5'], [selections.fetch(:other), '2:5'],
         [selections.fetch(:form), FORM_ARTICLES.fetch(grounded.fetch(:form))]].map do |selected, article|
          quoted = selected.fetch(:text).lines.map { |line| "> #{line.chomp}" }.join("\n")
          "#{quoted}\n> — [Art. #{article}](/laws/#{NUMAC}#art-#{article.tr(':', '-')})"
        end
      end

      def note_quote(grounded)
        quoted = grounded.fetch(:note).fetch(:note).lines.map { |line| "> #{line.chomp}" }.join("\n")
        "#{quoted}\n> — [Art. 6:13](/laws/#{NUMAC}#art-6-13)"
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
      'nl' => 'CORRECTIE: lees de werkelijke selectiezinnen van het meegeleverde artikel 2:5 en het meegeleverde vormspecifieke artikel. ' \
              'Verplaats expliciet genummerde verwijzingen die verkeerd zijn ingedeeld tussen statuten en andere bepalingen van de oprichtingsakte. ' \
              'Het vormspecifieke artikel verplicht zijn genoemde deelverzameling in de statuten; daaruit volgt niet dat overige gegevens daar verboden zijn. ' \
              'Behoud de beperking tot vennootschappen waarvoor de gegevens gelden en de werkelijke vernietigingsnota bij artikel 6:13. ' \
              'Gebruik alleen de meegeleverde bronlinks en verzin geen indeling. Schrijf het antwoord opnieuw zonder de correctie te noemen.',
      'fr' => 'CORRECTION : lisez les phrases de sélection réelles de l’article 2:5 fourni et de l’article propre à la forme fourni. ' \
              'Corrigez les références explicitement numérotées mal classées entre les statuts et les autres dispositions de l’acte constitutif. ' \
              'L’article propre à la forme impose son sous-ensemble dans les statuts ; il n’interdit pas d’y inclure les autres données. ' \
              'Conservez la limitation aux sociétés auxquelles les données s’appliquent et la note d’annulation réelle de l’article 6:13. ' \
              'Utilisez uniquement les liens fournis, sans inventer de classement. Réécrivez la réponse sans mentionner la correction.',
      'de' => 'KORREKTUR: lesen Sie die tatsächlichen Auswahlsätze des bereitgestellten Artikels 2:5 und des formbezogenen Artikels. ' \
              'Korrigieren Sie ausdrücklich nummerierte Verweise, die falsch zwischen Satzung und sonstigen Bestimmungen der Gründungsurkunde eingeordnet sind. ' \
              'Der formbezogene Artikel verlangt seine Teilmenge in der Satzung; andere Angaben werden dadurch dort nicht verboten. ' \
              'Bewahren Sie den Vorbehalt für betroffene Gesellschaften und den tatsächlichen Aufhebungshinweis zu Artikel 6:13. ' \
              'Verwenden Sie nur die bereitgestellten Links und erfinden Sie keine Einteilung. Schreiben Sie die Antwort ohne Erwähnung der Korrektur neu.',
      'en' => 'CORRECTION: read the actual selection sentences in supplied Article 2:5 and the supplied form-specific article. ' \
              'Correct explicit numbered references misclassified between articles of association and other provisions of the formation deed. ' \
              'The form-specific article requires its selected subset in the articles of association; it does not forbid including other data there. ' \
              'Keep the limitation to companies to which the data apply and the actual Article 6:13 annulment note. ' \
              'Use only supplied source links and do not invent a classification. Rewrite the answer without mentioning this correction.'
    }.freeze

    NOTICE_COPY = {
      'nl' => 'Brongebonden indeling: gebruik de volgende werkelijke selectiezinnen voor expliciet genummerde verwijzingen. Behoud hun toepasselijkheidsvoorbehoud; leid geen exclusieve indeling af uit een louter verplichte deelverzameling.',
      'fr' => 'Classement lié aux sources : utilisez les phrases de sélection réelles ci-dessous pour les références explicitement numérotées. Conservez leur réserve d’applicabilité ; ne déduisez pas un classement exclusif d’un simple sous-ensemble obligatoire.',
      'de' => 'Quellengebundene Einordnung: verwenden Sie die folgenden tatsächlichen Auswahlsätze für ausdrücklich nummerierte Verweise. Bewahren Sie den Anwendungsvorbehalt; leiten Sie aus einer verpflichtenden Teilmenge keine ausschließliche Zuordnung ab.',
      'en' => 'Source-bound classification: use these actual selection sentences for explicit numbered references. Keep their applicability qualification; do not infer an exclusive partition from a merely required subset.'
    }.freeze
    FALLBACK_COPY = {
      'nl' => '**Geverifieerde selectiezinnen:** Het gegenereerde overzicht kon niet volledig worden geverifieerd. Hieronder staan uitsluitend de werkelijk geraadpleegde selectiezinnen, geen vervangende checklist.',
      'fr' => '**Phrases de sélection vérifiées :** La liste générée n’a pas pu être entièrement vérifiée. Seules les phrases de sélection réellement consultées figurent ci-dessous, sans liste de remplacement.',
      'de' => '**Geprüfte Auswahlsätze:** Die erzeugte Übersicht konnte nicht vollständig verifiziert werden. Es folgen nur die tatsächlich konsultierten Auswahlsätze, keine Ersatzcheckliste.',
      'en' => '**Verified selection sentences:** The generated checklist could not be fully verified. Only the actually consulted selection sentences follow, not a replacement checklist.'
    }.freeze
  end
end
