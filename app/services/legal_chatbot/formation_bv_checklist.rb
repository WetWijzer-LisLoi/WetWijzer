# frozen_string_literal: true

module LegalChatbot
  # A bounded, source-derived recovery for a broad BV formation-deed question.
  # No model prose is reused: every checklist item is an exact retrieved clause.
  # The caller still has to run the normal quote/citation/grounding guard chain.
  class FormationBvChecklist
    NUMAC = FormationDeedClassification::NUMAC
    VERSION = 1
    CONDITION_CODES = %w[missing_formation_bv_source_grounding].freeze
    REQUIRED_ARTICLES = %w[2:5 2:8 5:12 5:1].freeze
    MAX_CLAUSE_CHARS = 2200
    FORM = /(?:bv|srl|besloten vennootschap|société à responsabilité limitée)/i
    QUESTION_PATTERNS = [
      /\A(?:wat\s+(?:moet|hoort|staat)\s+(?:er\s+)?(?:in|op)\s+(?:een|de)\s+(?:oprichtingsakte|akte\s+van\s+oprichting)|welke\s+(?:gegevens|vermeldingen)\s+moeten\s+in\s+(?:een|de)\s+(?:oprichtingsakte|akte\s+van\s+oprichting)(?:\s+staan)?)(?:\s+(?:van|voor)\s+(?:(?:een|de)\s+)?#{FORM.source})?(?:\s+staan)?\s*[?.!]?\s*(?:#{FORM.source})?\s*\z/i,
      /\A(?:que\s+doit\s+contenir|quelles\s+(?:données|mentions)\s+doit\s+contenir)\s+l['’]acte\s+constitutif(?:\s+d['’]une\s+#{FORM.source})?\s*[?.!]?\s*(?:#{FORM.source})?\s*\z/i,
      /\Awas\s+muss\s+(?:die|eine)\s+gründungsurkunde(?:\s+(?:einer|der)\s+#{FORM.source})?\s+enthalten\s*[?.!]?\s*(?:#{FORM.source})?\s*\z/i
    ].freeze
    PARAGRAPH_TWO = /(?:\A|\n)[[:space:]]*§\s*2\./
    PARAGRAPH_THREE = /(?:\A|\n)[[:space:]]*§\s*3\./
    ORDINAL = /(?:\A|\n)[[:blank:]]*(?<number>\d{1,2})[°º][[:blank:]]+/
    EEIG_SCOPE = {
      1 => /\A15°\s+voor\s+het\s+Europees\s+economisch\s+samenwerkingsverband:\s*\z/i,
      2 => /\A15°\s+pour\s+le\s+groupement\s+européen\s+d['’]intérêt\s+économique:\s*\z/i
    }.freeze
    NON_APPLICABILITY = {
      1 => /Op\s+de\s+vennootschap\s+onder\s+firma\s+en\s+de\s+commanditaire\s+vennootschap\s+zijn\s+de\s+punten\s+13°\s+en\s+14°\s+niet\s+van\s+toepassing\./i,
      2 => /Le\s+13°\s+et\s+le\s+14°\s+ne\s+sont\s+pas\s+applicables\s+à\s+la\s+société\s+en\s+nom\s+collectif\s+et\s+à\s+la\s+société\s+en\s+commandite\./i
    }.freeze
    EEIG_C_ENDING = {
      1 => /De\s+Koning\s+kan\s+bij\s+in\s+Ministerraad\s+overlegd\s+besluit\s+de\s+soorten\s+Europese\s+economisch\s+samenwerkingsverbanden\s+bepalen\s+die\s+van\s+deze\s+vereiste\s+worden\s+vrijgesteld\.\z/i,
      2 => /Le\s+Roi\s+peut,\s*par\s+arrêté\s+délibéré\s+en\s+Conseil\s+des\s+ministres,\s*déterminer\s+les\s+catégories\s+de\s+groupements\s+européens\s+d['’]intérêt\s+économique\s+dispensés\s+de\s+cette\s+formalité\.\z/i
    }.freeze
    GENERAL_PREFIX = {
      1 => /\AHet\s+uittreksel\s+uit\s+de\s+oprichtingsakte\s+bedoeld\s+in\s+paragraaf\s+1,\s*2°,\s*bevat:\s*\z/i,
      2 => /\AL['’]extrait\s+de\s+l['’]acte\s+constitutif\s+visé\s+au\s+paragraphe\s+1er,\s*2°,\s*du\s+présent\s+article\s+contient:\s*\z/i
    }.freeze
    SPECIFIC_PREFIX = {
      1 => /\AArt\.\s*5:12\.\s*Naast\s+de\s+gegevens\s+opgenomen\s+in\s+het\s+uittreksel\s+bestemd\s+voor\s+bekendmaking\s+overeenkomstig\s+artikel\s+2:8,\s*§\s*2,\s*worden\s+in\s+de\s+oprichtingsakte\s+de\s+volgende\s+gegevens\s+vermeld:\s*\z/i,
      2 => /\AArt\.\s*5:12\.\s*Outre\s+les\s+données\s+comprises\s+dans\s+l['’]extrait\s+destiné\s+à\s+la\s+publication\s+en\s+vertu\s+de\s+l['’]article\s+2:8,\s*§\s*2,\s*l['’]acte\s+constitutif\s+mentionne\s+les\s+données\s+suivantes:\s*\z/i
    }.freeze
    AUTHENTIC_SENTENCE = {
      1 => /Besloten\s+vennootschappen,[^\n]{1,450}?worden,\s*op\s+straffe\s+van\s+nietigheid,\s*opgericht\s+bij\s+authentieke\s+akte\./i,
      2 => /Les\s+sociétés\s+à\s+responsabilité\s+limitée,[^\n]{1,450}?sont,\s*à\s+peine\s+de\s+nullité,\s*constituées\s+par\s+acte\s+authentique\./i
    }.freeze
    VOLMACHT = {
      1 => /In\s+de\s+volmachten\s+moeten\s+de\s+door\s+artikel\s+2:8,\s*§\s*2,\s*1°,\s*2°,\s*3°\s+en\s+12°,\s*voorgeschreven\s+vermeldingen\s+worden\s+opgenomen\./i,
      2 => /Les\s+procurations\s+doivent\s+reproduire\s+les\s+énonciations\s+prévues\s+par\s+l['’]article\s+2:8,\s*§\s*2,\s*1°,\s*2°,\s*3°\s+et\s+12°\./i
    }.freeze

    class << self
      # A broad checklist must retain the actual allocation rules, not merely
      # survive citation stripping. This checks source evidence, not the legal
      # meaning of arbitrary paraphrases, and only applies with complete rows.
      def evaluate(answer, question, sources)
        data = evidence(question, sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless data

        blocks = answer.to_s.scan(/(?:\A|\n)(?:[ \t]*>[^\n]*(?:\n|\z))+/).map do |block|
          block.lines.map { |line| line.sub(/\A[ \t]*>[ \t]?/, '') }.join.gsub(/[[:space:]]+/, ' ').strip
        end
        selections_present = { statutes: '2:5', other: '2:5', form: '5:12' }.all? do |group, article|
          selection = data.fetch(:allocation).fetch(group).fetch(:text).gsub(/[[:space:]]+/, ' ')
          query = data.fetch(:language_id) == 2 ? '?language_id=2' : ''
          attribution = Regexp.new("— \\[Art\\. #{Regexp.escape(article)}\\]\\((?:https://wetwijzer\\.be)?/laws/#{NUMAC}#{Regexp.escape(query)}#art-#{article.tr(':', '-')}\\)\\z")
          blocks.any? { |block| block.include?(selection) && block.match?(attribution) }
        end
        missing = selections_present ? [] : CONDITION_CODES.dup
        { applicable: true, missing_conditions: missing, version: VERSION }
      end

      def corrective_feedback(codes, language: 'nl')
        return nil unless Array(codes).map(&:to_s).intersect?(CONDITION_CODES)

        FEEDBACK.fetch(language.to_s, FEEDBACK.fetch('nl'))
      end

      def fallback(question, sources, language: 'nl')
        data = evidence(question, sources)
        return nil unless data

        copy = COPY.fetch(language.to_s, COPY.fetch('nl'))
        parts = [copy.fetch(:intro), copy.fetch(:form), quote(data.fetch(:authentic), '2:5', data),
                 quote(data.fetch(:capital), '5:1', data), copy.fetch(:qualification),
                 copy.fetch(:statutes), quote(data.fetch(:allocation).fetch(:statutes).fetch(:text), '2:5', data)]
        parts.concat(common_quotes(data, :statutes))
        parts << copy.fetch(:other)
        parts << quote(data.fetch(:allocation).fetch(:other).fetch(:text), '2:5', data)
        parts.concat(common_quotes(data, :other))
        parts << copy.fetch(:specific)
        parts << quote(data.fetch(:specific_intro), '5:12', data)
        parts << quote(data.fetch(:allocation).fetch(:form).fetch(:text), '5:12', data)
        parts << copy.fetch(:specific_statutes)
        data.fetch(:mandatory_specific).each { |point| parts << quote(data.fetch(:specific).fetch(point), '5:12', data) }
        parts << copy.fetch(:specific_remaining)
        (data.fetch(:specific).keys - data.fetch(:mandatory_specific)).each do |point|
          parts << quote(data.fetch(:specific).fetch(point), '5:12', data)
        end
        parts << copy.fetch(:proxy)
        parts << quote(data.fetch(:proxy), '5:12', data)
        parts << copy.fetch(:eeig)
        parts << quote(data.fetch(:eeig_scope), '2:8', data)
        parts << copy.fetch(:boundary)
        parts.join("\n\n")
      end

      private

      def evidence(question, sources)
        normalized = question.to_s.gsub(/[[:space:]]+/, ' ').strip
        return nil unless QUESTION_PATTERNS.any? { |pattern| normalized.match?(pattern) }
        return nil unless FormationDeedClassification.topic_form(normalized) == :bv

        grounded = FormationDeedClassification.evidence(normalized, sources)
        return nil unless grounded&.fetch(:reference_source)

        lane = grounded.fetch(:language_id)
        selected = Array(sources).select { |source| field(source, :language_id) == lane }
        return nil unless REQUIRED_ARTICLES.all? { |article| unique_source?(selected, article) }

        capital = FormationBvCapitalGrounding.evidence(selected)
        return nil unless capital && capital.fetch(:language_id) == lane

        common = common_clauses(source_text(grounded.fetch(:reference_source)), lane)
        specific = specific_clauses(source_text(grounded.fetch(:form_source)), grounded, lane)
        authentic = unique_match(source_text(grounded.fetch(:common_source)), AUTHENTIC_SENTENCE.fetch(lane))
        return nil unless common && specific && authentic
        return nil unless valid_allocation?(grounded.fetch(:selections))

        { language_id: lane, common: common.fetch(:clauses), eeig_scope: common.fetch(:eeig_scope),
          specific: specific.fetch(:clauses), specific_intro: specific.fetch(:intro), proxy: specific.fetch(:proxy),
          authentic: authentic, capital: trim(source_text(capital.fetch(:source))),
          allocation: grounded.fetch(:selections), mandatory_specific: grounded.fetch(:form_mandatory).map(&:first) }
      end

      # Count even conflicting or malformed duplicate rows. The existing evidence
      # readers choose a matching row; a compiled checklist must not choose among
      # competing records for the same canonical article and language lane.
      def unique_source?(sources, article)
        matches = sources.select do |source|
          field(source, :numac).to_s == NUMAC &&
            (field(source, :article_number).presence || field(source, :article_title)).to_s
              .match?(/\A\s*(?:Art(?:ikel|icle)?\.?\s*)?#{Regexp.escape(article)}\.?\s*\z/i)
        end
        return false unless matches.one?

        %i[article_number article_title].all? do |key|
          value = field(matches.first, key)
          value.blank? || value.to_s.match?(/\A\s*(?:Art(?:ikel|icle)?\.?\s*)?#{Regexp.escape(article)}\.?\s*\z/i)
        end
      end

      def common_clauses(text, lane)
        starts = matches(text, PARAGRAPH_TWO)
        endings = matches(text, PARAGRAPH_THREE)
        return nil unless starts.one? && endings.one? && starts.first.end(0) < endings.first.begin(0)

        section = text[starts.first.end(0)...endings.first.begin(0)]
        ordinal_matches = matches(section, ORDINAL)
        return nil unless ordinal_matches.map { |match| match[:number].to_i } == (1..15).to_a
        return nil unless trim(section[0...ordinal_matches.first.begin(0)]).match?(GENERAL_PREFIX.fetch(lane))

        clauses = extract_clauses(section, ordinal_matches, count: 14)
        return nil unless clauses

        fifteenth = trim(section[ordinal_matches.last.begin(0)..])
        subletters = matches(fifteenth, /(?:\A|\n)[[:blank:]]*(?<letter>[a-c])\)[[:blank:]]+/)
        return nil unless subletters.map { |match| match[:letter] } == %w[a b c]

        scope = trim(fifteenth[0...subletters.first.begin(0)])
        return nil unless scope.match?(EEIG_SCOPE.fetch(lane))

        # The whole point is required for parser completeness, but its selected
        # a/b clauses are scoped to EEIGs and therefore not BV checklist items.
        first_two = subletters.first(2).each_with_index.map do |match, index|
          trim(fifteenth[match.begin(0)...subletters[index + 1].begin(0)])
        end
        return nil unless first_two.all? { |clause| complete_clause?(clause) }

        ending = matches(fifteenth, NON_APPLICABILITY.fetch(lane))
        return nil unless ending.one? && ending.first.begin(0) > subletters.last.end(0)

        final_clause = trim(fifteenth[subletters.last.begin(0)...ending.first.begin(0)])
        return nil unless complete_clause?(final_clause) && final_clause.match?(EEIG_C_ENDING.fetch(lane))
        return nil unless trim(fifteenth[ending.first.end(0)..]).empty?

        { clauses: clauses, eeig_scope: scope }
      end

      def specific_clauses(text, grounded, lane)
        ordinal_matches = matches(text, ORDINAL)
        return nil unless ordinal_matches.map { |match| match[:number].to_i } == (1..8).to_a

        intro = trim(text[0...ordinal_matches.first.begin(0)])
        return nil unless intro.match?(SPECIFIC_PREFIX.fetch(lane))

        allocation = grounded.fetch(:selections).fetch(:form).fetch(:text)
        return nil unless text.scan(Regexp.new(Regexp.escape(allocation))).one?

        allocation_start = text.index(allocation)
        return nil unless allocation_start > ordinal_matches.last.end(0)

        body = text[0...allocation_start]
        clauses = extract_clauses(body, ordinal_matches, count: 8)
        proxy = unique_match(text[(allocation_start + allocation.length)..], VOLMACHT.fetch(lane))
        return nil unless clauses && proxy
        return nil unless trim(text[(allocation_start + allocation.length)..]) == proxy

        { clauses: clauses, intro: intro, proxy: proxy }
      end

      def extract_clauses(text, ordinal_matches, count:)
        result = ordinal_matches.first(count).each_with_index.to_h do |match, index|
          ending = ordinal_matches[index + 1]&.begin(0) || text.length
          [match[:number].to_i, trim(text[match.begin(0)...ending])]
        end
        result if result.values.all? { |clause| complete_clause?(clause) }
      end

      def complete_clause?(clause)
        clause.present? && clause.length <= MAX_CLAUSE_CHARS && clause.end_with?(';', '.') &&
          !clause.match?(/\.\.\.|…/) &&
          clause.gsub(/\[\d+\s+[^\]]+\]\d+/, '').exclude?('[') &&
          clause.gsub(/\[\d+\s+[^\]]+\]\d+/, '').exclude?(']')
      end

      def valid_allocation?(allocation)
        general = allocation.fetch(:statutes).fetch(:points) + allocation.fetch(:other).fetch(:points)
        expected = (1..14).map { |number| [number, nil] } + [[15, 'a'], [15, 'b']]
        general.sort_by(&:to_s) == expected.sort_by(&:to_s) &&
          allocation.fetch(:form).fetch(:points).all? { |number, letter| number.between?(1, 8) && letter.nil? }
      end

      def common_quotes(data, group)
        data.fetch(:allocation).fetch(group).fetch(:points).filter_map do |number, letter|
          next if letter

          quote(data.fetch(:common).fetch(number), '2:8', data)
        end
      end

      def quote(text, article, data)
        quoted = text.lines.map { |line| "> #{line.chomp}" }.join("\n")
        query = data.fetch(:language_id) == 2 ? '?language_id=2' : ''
        "#{quoted}\n> — [Art. #{article}](/laws/#{NUMAC}#{query}#art-#{article.tr(':', '-')})"
      end

      def unique_match(text, pattern)
        found = matches(text, pattern)
        trim(found.first[0]) if found.one?
      end

      def matches(text, pattern)
        text.to_enum(:scan, pattern).map { Regexp.last_match.dup }
      end

      def source_text(source)
        field(source, :article_text, :text, :full_text, :content).to_s
      end

      def trim(text)
        text.to_s.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
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

    FEEDBACK = {
      'nl' => 'CORRECTIE: Behoud bij dit BV-overzicht de drie exacte selectiezinnen uit de geraadpleegde artikelen 2:5 en 5:12, met hun canonieke bronlinks. Zij bepalen welke gegevens in de statuten horen. Een opsomming zonder deze brononderbouwing is geen geverifieerde indeling. Verplaats geen andere aktegegevens naar de verplichte statuten.',
      'fr' => 'CORRECTION : Conservez dans cet aperçu de la SRL les trois phrases exactes de sélection des articles consultés 2:5 et 5:12, avec leurs liens canoniques. Elles déterminent les données à reprendre dans les statuts. Une liste sans ces preuves ne constitue pas une répartition vérifiée. Ne déplacez pas les autres données de l’acte vers les statuts obligatoires.',
      'de' => 'KORREKTUR: Behalten Sie in dieser BV-Übersicht die drei genauen Auswahlsätze aus den konsultierten Artikeln 2:5 und 5:12 mit ihren kanonischen Quellenlinks bei. Sie bestimmen die Satzungsangaben. Eine Liste ohne diese Quellenbelege ist keine geprüfte Zuordnung. Ordnen Sie andere Urkundenangaben nicht der zwingenden Satzung zu.',
      'en' => 'CORRECTION: Retain the three exact allocation sentences from retrieved Articles 2:5 and 5:12, with their canonical source links, in this BV checklist. They determine which data belong in the articles of association. A list without that source evidence is not a verified partition. Do not move other deed data into the mandatory articles of association.'
    }.freeze

    COPY = {
      'nl' => {
        intro: '**Geverifieerd overzicht voor een BV:** Hieronder staat de inhoud van de oprichtingsakte, met de exacte wettelijke vermeldingen per onderdeel. De voorwaarden in de citaten blijven gelden; dit is geen op maat gemaakte akte.',
        form: '### Aktevorm en de BV zonder kapitaal',
        qualification: 'De algemene kapitaalvermelding hieronder geldt alleen “in voorkomend geval”: zij maakt van een BV geen vennootschap met verplicht kapitaal.',
        statutes: '### Algemene gegevens voor de statuten — voor zover toepasselijk',
        other: '### Algemene gegevens voor de andere bepalingen van de oprichtingsakte',
        specific: '### Aanvullende BV-gegevens voor de oprichtingsakte',
        specific_statutes: '**Deze BV-gegevens moeten in het deel met de statuten staan:**',
        specific_remaining: '**De overige BV-gegevens moeten ook in de oprichtingsakte staan. De geciteerde selectie verbiedt niet om ze eveneens in de statuten op te nemen:**',
        proxy: '### Als er volmachten worden gebruikt',
        eeig: '### Niet op de BV van toepassing',
        boundary: 'Het geciteerde toepassingsgebied van punt 15 betreft een Europees economisch samenwerkingsverband, niet een BV. Daarom worden de ledengegevens van dat punt hier niet als BV-vereisten opgenomen. Dit overzicht behandelt de akte-inhoud; neerlegging en andere oprichtingsformaliteiten zijn afzonderlijke vragen.'
      },
      'fr' => {
        intro: '**Aperçu vérifié pour une SRL :** Voici le contenu de l’acte constitutif, avec les mentions légales exactes par partie. Les conditions figurant dans les citations restent applicables ; il ne s’agit pas d’un acte personnalisé.',
        form: '### Forme de l’acte et SRL sans capital',
        qualification: 'La mention générale du capital ci-dessous ne vaut que « le cas échéant » : elle n’impose pas un capital à la SRL.',
        statutes: '### Données générales pour les statuts — dans la mesure où elles sont applicables',
        other: '### Données générales pour les autres dispositions de l’acte constitutif',
        specific: '### Données supplémentaires de la SRL pour l’acte constitutif',
        specific_statutes: '**Ces données de la SRL doivent figurer dans la partie contenant les statuts :**',
        specific_remaining: '**Les autres données de la SRL doivent aussi figurer dans l’acte constitutif. La sélection citée n’interdit pas de les inclure également dans les statuts :**',
        proxy: '### Si des procurations sont utilisées',
        eeig: '### Non applicable à la SRL',
        boundary: 'Le champ d’application cité du point 15 concerne un groupement européen d’intérêt économique, pas une SRL. Ses données relatives aux membres ne sont donc pas présentées ici comme des exigences de la SRL. Cet aperçu porte sur le contenu de l’acte ; le dépôt et les autres formalités de constitution sont des questions distinctes.'
      },
      'de' => {
        intro: '**Geprüfte Übersicht für eine BV:** Es folgt der Inhalt der Gründungsurkunde mit den genauen gesetzlichen Angaben je Abschnitt. Die Bedingungen in den Zitaten bleiben maßgeblich; dies ist keine individuell ausgearbeitete Urkunde.',
        form: '### Urkundenform und BV ohne Kapital',
        qualification: 'Die allgemeine Kapitalangabe unten gilt nur gegebenenfalls; daraus entsteht keine Kapitalpflicht für eine BV.',
        statutes: '### Allgemeine Angaben für die Satzung — soweit anwendbar',
        other: '### Allgemeine Angaben für die sonstigen Bestimmungen der Gründungsurkunde',
        specific: '### Zusätzliche BV-Angaben für die Gründungsurkunde',
        specific_statutes: '**Diese BV-Angaben gehören in den Satzungsteil:**',
        specific_remaining: '**Die übrigen BV-Angaben gehören ebenfalls in die Gründungsurkunde. Die zitierte Auswahl verbietet nicht, sie auch in die Satzung aufzunehmen:**',
        proxy: '### Wenn Vollmachten verwendet werden',
        eeig: '### Nicht auf die BV anwendbar',
        boundary: 'Der zitierte Anwendungsbereich von Punkt 15 betrifft eine Europäische wirtschaftliche Interessenvereinigung, keine BV. Ihre Mitgliederangaben werden deshalb hier nicht als BV-Anforderungen aufgenommen. Diese Übersicht betrifft den Urkundeninhalt; Hinterlegung und andere Gründungsformalitäten sind gesonderte Fragen.'
      },
      'en' => {
        intro: '**Verified BV checklist:** Below is the content of the formation deed, with the exact statutory requirements grouped by part. Qualifications in the quotations remain applicable; this is not a bespoke deed.',
        form: '### Form of the deed and the BV without capital',
        qualification: 'The general capital item below applies only where applicable; it does not impose a capital requirement on a BV.',
        statutes: '### General data for the articles of association — where applicable',
        other: '### General data for other provisions of the formation deed',
        specific: '### Additional BV data for the formation deed',
        specific_statutes: '**These BV items belong in the part containing the articles of association:**',
        specific_remaining: '**The remaining BV data also belong in the formation deed. The quoted selection does not prohibit including them in the articles of association as well:**',
        proxy: '### If powers of attorney are used',
        eeig: '### Not applicable to the BV',
        boundary: 'The quoted scope of point 15 concerns a European economic interest grouping, not a BV. Its member information is therefore not included here as a BV requirement. This checklist concerns deed content; filing and other formation formalities are separate questions.'
      }
    }.transform_values(&:freeze).freeze
  end
end
