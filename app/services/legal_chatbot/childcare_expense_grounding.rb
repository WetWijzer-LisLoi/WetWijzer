# frozen_string_literal: true

module LegalChatbot
  # A narrow, evidence-bound check for the 2026-10-10 childcare diagnosis.
  # This is NOT a verifier of arbitrary legal conclusions. It ensures that
  # an answer about this decree cannot omit its decisive age/qualification
  # clauses or turn an unspecified school-care label into a categorical rule.
  # No source lookup or legal fact is synthesized here: all quoted clauses
  # must occur in the retrieved Article 1 of this exact decree.
  class ChildcareExpenseGrounding
    NUMAC = '2019012051'
    VERSION = 1
    CHILDCARE_PATTERN = /\b(?:schoolse\s*opvang|naschoolse\s*opvang|buitenschoolse\s*opvang|kinderopvang|opvangkosten|garderie|accueil\s+(?:extra)?scolaire|garde\s+d['’]enfants|child\s*care|after[- ]school\s+care|schulbetreuung(?:skosten)?|kinderbetreuung(?:skosten)?)\b/i
    FAMILY_EXPENSE_PATTERN = /\b(?:familierecht|buitengewone\s+kost(?:en)?|vaste\s+kosten|ouders?|ouder|onderhoudsbijdrage|frais\s+(?:extraordinaires?|fixes)|parents?|droit\s+de\s+la\s+famille|extraordinary\s+expenses?|fixed\s+costs|family\s+law|parent(?:s)?|(?:außer|ausser)gew[oö]hnlich(?:e|en|er|es|em)\s+kosten|familienrecht|eltern)\b|(?:\b(?:kb|ar|arrêté\s+royal|royal\s+decree|königlich(?:er|en|e|es|em)\s+erlass(?:es)?)\b.*\b2019\b)|#{NUMAC}/i
    AGE_PATTERN = %r{\b(?:0\s*(?:tot\s+en\s+met|t/m|t\.e\.m\.)\s*3|0\s+tot\s+3(?:\s+jaar)?\s+inclusief|nul\s+tot\s+en\s+met\s+drie|(?:0|z[eé]ro)\s+[àa]\s+(?:3|trois)\s+ans\s+inclus|(?:0|zero)\s+(?:to|through)\s+(?:3|three)(?:\s+years?)?\s+inclusive|(?:0|null)\s+bis\s+(?:3|drei)(?:\s+jahr(?:e|en)?)?\s+einschlie(?:ß|ss)lich|(?:0|null)\s+bis\s+einschlie(?:ß|ss)lich\s+(?:3|drei))\b}i
    WRONG_BOUNDARY_PATTERN = %r{\b(?:kinderopvang|garde\s+d['’]enfants|child\s*care|kinderbetreuung(?:skosten)?)\b[^.!?\n]{0,100}\b(?:0|nul|z[eé]ro|zero|null)\s*(?:tot(?:\s+en\s+met)?|t/m|t\.e\.m\.|[àa]|bis(?:\s+einschlie(?:ß|ss)lich)?|to|through|[-–])\s*(?:2|4|twee|vier|deux|quatre|two|four|zwei)\b}i
    AGREEMENT_PATTERN = /\b(?:overeenkomst(?:en)?|akkoord(?:en)?|conventions?|accords?|agreements?|vereinbarung(?:en)?|(?:afwijkende|andersluidende|gezamenlijke|onderlinge)\s+afspraken)\b/i
    COURT_PATTERN = /\b(?:rechter(?:lijke)?|vonnis|rechtbank|gerechtelijke\s+(?:beslissing(?:en)?|uitspra(?:ak|ken))|judiciaires?|juges?|jugement|tribunal|tribunaux|d[eé]cision\s+de\s+justice|courts?|judg(?:e|ment)|judicial\s+(?:decisions?|orders?|rulings?)|gericht(?:liche[rsn]?)?|gerichtsentscheidung|gerichtsbeschluss|richter)\b/i
    EXTRAORDINARY_PATTERN = /\b(?:buitengewone\s+kost(?:en)?|frais\s+extraordinaires?|extraordinary\s+(?:expenses?|costs?)|(?:außer|ausser)gew[oö]hnlich(?:e|en|er|es|em)\s+kosten)\b/i
    CONDITIONAL_PATTERN = /\b(?:als|indien|mits|tenzij|behoudens|voor\s+zover|sauf|si|depending\s+on|unless|if|provided\s+that|wenn|sofern)\b/i
    NOT_AUTOMATIC_PATTERN = /\b(?:niet\s+automatisch|pas\s+automatiquement|not\s+automatically|nicht\s+automatisch)\b/i
    CATEGORICAL_SCHOOLCARE_PATTERN = /\b(?:schoolse\s*opvang|naschoolse\s*opvang|buitenschoolse\s*opvang|garderie|accueil\s+(?:extra)?scolaire|after[- ]school\s+care|schulbetreuung)\b[^.!?\n]{0,180}\b(?:valt\s+(?:niet\s+)?onder|(?:is|zijn)\s+(?:geen|altijd|nooit)|(?:n['’]est\s+pas|est\s+toujours)|(?:is\s+not|is\s+always|is\s+never)|(?:ist\s+kein|ist\s+immer|ist\s+nie))\b/i
    DISABILITY_PATTERN = /\b(?:handicap|gehandicapt|handicap[eé]s?|disab(?:ility|led)|behinderung|behindert|kind(?:eren)?\s+met\s+(?:een\s+)?beperking)\b/i
    REGIONAL_2014_PATTERN = /(?:\b2014\b.{0,100}\b(?:besluit|decreet|decree|arrêté|d[eé]cret|erlass)\b|\b(?:besluit|decreet|decree|arrêté|d[eé]cret|erlass)\b.{0,100}\b2014\b)/i

    class << self
      def topic?(question)
        question.to_s.match?(CHILDCARE_PATTERN) && question.to_s.match?(FAMILY_EXPENSE_PATTERN)
      end

      def evidence(sources)
        Array(sources).each do |source|
          next unless field(source, :numac).to_s == NUMAC

          number = field(source, :article_number).presence || field(source, :article_title)
          next unless number.to_s.match?(/\A\s*(?:Art(?:ikel|icle)?\.?\s*)?1(?:er)?\.?\s*\z/i)

          # Only the explicitly identified Dutch/French corpus rows are
          # binding here. Do not turn nil, strings or arbitrary numeric IDs
          # into an apparently canonical language by coercion.
          language_id = field(source, :language_id)
          next unless language_id.is_a?(Integer) && [1, 2].include?(language_id)

          text = field(source, :article_text, :text, :full_text, :content).to_s
          clauses = extract_clauses(text)
          return clauses.merge(source: source) if clauses
        end
        nil
      end

      # Keep these exact spans together when the ordinary article budget
      # truncates the long medical/school-cost list before the childcare item.
      # The caller must already have retrieved this Article 1; no backfill is
      # performed and nothing is emitted for another/incomplete source.
      def verified_excerpt(source)
        grounded = evidence([source])
        return nil unless grounded

        grounded.values_at(:qualification, :age_clause, :other_costs).join("\n")
      end

      def guidance(question, context)
        return nil unless topic?(question)

        block = context.to_s.split("\n\n---\n\n").find do |candidate|
          candidate.match?(/^NUMAC:\s*#{NUMAC}\s*$/) &&
            candidate.match?(%r{^LINK:\s*/laws/#{NUMAC}(?:\?language_id=[12])?#art[-_]1\s*$}) &&
            extract_clauses(candidate)
        end
        return nil unless block

        <<~GUIDANCE.strip
          CHILDCARE APPLICATION CHECK (task instruction, not an additional legal source):
          - The supplied decree concerns extraordinary expenses, not a general category of fixed costs. Correct that terminology if the question confuses it.
          - Explain the childcare age condition explicitly, including the upper age boundary, using the actual Article 1 wording supplied above.
          - Explain both the agreement/court-decision qualification at the beginning and the jointly agreed/court-qualified other costs at the end of Article 1.
          - The label "school care" does not by itself establish the child's age or the applicable agreement/order. Do not answer categorically that all school care is included or excluded; identify the facts and conditions needed to apply this source. If facts are provided, apply them conditionally rather than pretending they were not supplied.
          - A parent's individual choice of childcare is not, by itself, a classification rule in this source. Do not invent disability exceptions or import a regional childcare decree's cost classification into this family-expense decree.
          - Mention prior consultation/agreement and its exceptions only if the relevant Article 2 text is actually supplied. Never invent a quotation, a missing provision, or a missing factual answer.
          - Write the answer in the requested language; a statutory quotation remains verbatim in its supplied original language.
        GUIDANCE
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) && evidence(sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded

        visible = answer.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1')
        missing = []
        missing << 'childcare_age_boundary' unless visible.match?(AGE_PATTERN)
        missing << 'childcare_wrong_age_boundary' if visible.match?(WRONG_BOUNDARY_PATTERN)
        missing << 'childcare_agreement_or_order' unless visible.match?(AGREEMENT_PATTERN) && visible.match?(COURT_PATTERN)
        missing << 'extraordinary_not_fixed_costs' unless visible.match?(EXTRAORDINARY_PATTERN)
        missing << 'childcare_source_citation' unless answer.to_s.match?(%r{\[[^\]]+\]\(/laws/#{NUMAC}(?:\?language_id=[12])?#art[-_]1\)})

        # The observed defect said "school care is excluded" without the
        # child's age or the agreement/order. Only catch that narrow assertion
        # shape, not arbitrary legal prose; explicit conditional application
        # remains possible for a question that supplies the relevant facts.
        sentences = visible.split(/(?<=[.!?])\s+|\n/)
        sentences.each do |sentence|
          conditional = sentence.match?(NOT_AUTOMATIC_PATTERN) ||
                        (sentence.match?(CONDITIONAL_PATTERN) &&
                         (sentence.match?(AGE_PATTERN) || sentence.match?(AGREEMENT_PATTERN) || sentence.match?(COURT_PATTERN)))
          missing << 'unqualified_schoolcare_classification' if sentence.match?(CATEGORICAL_SCHOOLCARE_PATTERN) && !conditional
        end
        if sentences.any? { |sentence| sentence.match?(DISABILITY_PATTERN) && !unsupported_basis_disclaimer?(sentence) } &&
           !question.to_s.match?(DISABILITY_PATTERN) &&
           !grounded.values_at(:qualification, :age_clause, :other_costs).join(' ').match?(DISABILITY_PATTERN)
          missing << 'unsupported_childcare_disability_exception'
        end
        if sentences.any? { |sentence| sentence.match?(REGIONAL_2014_PATTERN) && !unsupported_basis_disclaimer?(sentence) } &&
           !question.to_s.match?(REGIONAL_2014_PATTERN)
          missing << 'unrelated_regional_childcare_classification'
        end
        { applicable: true, missing_conditions: missing.uniq, version: VERSION }
      end

      def corrective_feedback(missing_conditions)
        codes = Array(missing_conditions).map(&:to_s) & CONDITION_CODES
        return nil if codes.empty?

        <<~FEEDBACK.strip
          CORRECTION - the previous childcare answer omitted or misstated a decisive condition of the supplied extraordinary-expenses decree and was NOT shown to the user.
          Write the complete answer again. Explicitly include the Article 1 childcare age boundary (0 through 3 inclusive), its agreement/court-decision qualification, and its jointly agreed/court-qualified other-costs clause, citing the supplied Article 1 link.
          Correct "fixed costs" to extraordinary expenses where needed. Do not categorically include/exclude unspecified school care: distinguish the child's age and applicable agreement/order, and ask only for facts the question has not supplied.
          Do not invent a disability exception or use a regional 2014 childcare decree as the family-expense classification. If you cannot ground the answer in the supplied text, say so rather than inventing a rule.
          Do not mention this correction or the rejected attempt.
        FEEDBACK
      end

      def fallback(question, sources, language: 'nl')
        grounded = topic?(question) && evidence(sources)
        return nil unless grounded

        copy = FALLBACK_COPY.fetch(language.to_s, FALLBACK_COPY.fetch('nl'))
        paragraphs = [copy.fetch(:heading), copy.fetch(:intro)]
        grounded.values_at(:qualification, :age_clause, :other_costs).each do |clause|
          paragraphs << "> #{clause}\n> — [Art. 1](/laws/#{NUMAC}#art-1)"
        end
        paragraphs << copy.fetch(:facts)
        paragraphs.join("\n\n")
      end

      private

      # A warning that a supposed exception/basis is NOT established must not
      # itself be treated as an assertion of that exception/basis. Keep this
      # bound to explicit negation near the exception/basis wording; a bare
      # "not" elsewhere cannot launder an affirmative claim.
      def unsupported_basis_disclaimer?(sentence)
        sentence.match?(
          /(?:\b(?:geen|niet|aucune?|pas|not|no|kein(?:e[rsn]?)?|nicht)\b.{0,65}\b(?:uitzondering|grondslag|basis|exception|fondement|legal\s+basis|ausnahme|rechtsgrundlage)\b|\b(?:uitzondering|grondslag|basis|exception|fondement|legal\s+basis|ausnahme|rechtsgrundlage)\b.{0,65}\b(?:niet|pas|not|nicht)\b)/i
        )
      end

      def extract_clauses(text)
        # Capture the source's own contiguous strings, never rebuild a quote
        # from translated/canned legal wording. Missing any decisive clause
        # leaves this specialized grounding inactive.
        qualification = text[/\bBehoudens andersluidende overeenkomst of rechterlijke beslissing[^:]{0,500}:/i] ||
                        text[/\bSauf convention ou d[eé]cision judiciaire contraires?[^:]{0,500}:/i]
        age_clause = text[/\bkosten voor kinderopvang voor kinderen van 0\s+tot en met\s+3\s+jaar[;.]?/i] ||
                     text[/\bles frais de garde d['’]enfants de 0\s+[àa]\s+3\s+ans inclus[;.]?/i]
        other_costs = text[/\bAlle overige kosten die de ouders in een gezamenlijk akkoord als buitengewoon benoemen of die als zodanig door de rechter gekwalificeerd worden[.]?/i] ||
                      text[/\bTous les autres frais que les parents qualifient d['’]un commun accord de frais extraordinaires, ou ainsi qualifi[eé]s par le juge[.]?/i]
        return nil unless qualification && age_clause && other_costs

        { qualification: qualification, age_clause: age_clause, other_costs: other_costs }
      end

      def field(source, *keys)
        keys.each do |key|
          if source.respond_to?(:[])
            [key, key.to_s].each do |candidate|
              value = source[candidate]
              return value unless value.nil?
            rescue IndexError, TypeError, NameError
              nil
            end
          end
          return source.public_send(key) if source.respond_to?(key) && !source.public_send(key).nil?
        end
        nil
      end
    end

    CONDITION_CODES = %w[
      childcare_age_boundary childcare_wrong_age_boundary childcare_agreement_or_order extraordinary_not_fixed_costs
      childcare_source_citation unqualified_schoolcare_classification
      unsupported_childcare_disability_exception unrelated_regional_childcare_classification
    ].freeze

    FALLBACK_COPY = {
      'nl' => {
        heading: '**Geverifieerde bron, met toepassingsvoorwaarden:**',
        intro: 'Het KB van 22 april 2019 betreft buitengewone kosten, niet een algemene categorie "vaste kosten". De geraadpleegde bepaling bevat de volgende voorwaarden:',
        facts: 'De benaming "schoolse opvang" alleen volstaat niet om deze voorwaarden op uw situatie toe te passen. Controleer de leeftijd van het kind en wat de overeenkomst of rechterlijke beslissing bepaalt. Een algemene ja/nee-conclusie zonder die gegevens is niet gerechtvaardigd op basis van deze bron.'
      },
      'fr' => {
        heading: '**Source vérifiée, avec ses conditions d’application :**',
        intro: 'L’arrêté royal du 22 avril 2019 concerne les frais extraordinaires, et non une catégorie générale de "frais fixes". La disposition consultée contient les conditions suivantes :',
        facts: 'La seule appellation "garderie scolaire" ne suffit pas pour appliquer ces conditions à votre situation. Vérifiez l’âge de l’enfant et ce que prévoit la convention ou la décision judiciaire. Cette source ne justifie pas une conclusion générale oui/non sans ces éléments.'
      },
      'de' => {
        heading: '**Geprüfte Quelle mit ihren Anwendungsbedingungen:**',
        intro: 'Der Königliche Erlass vom 22. April 2019 betrifft außergewöhnliche Kosten, nicht eine allgemeine Kategorie von "Fixkosten". Die konsultierte Bestimmung enthält die folgenden Bedingungen:',
        facts: 'Die Bezeichnung "Schulbetreuung" allein genügt nicht, um diese Bedingungen auf Ihren Fall anzuwenden. Prüfen Sie das Alter des Kindes und die Vereinbarung oder gerichtliche Entscheidung. Ohne diese Angaben rechtfertigt diese Quelle keine allgemeine Ja/Nein-Aussage.'
      },
      'en' => {
        heading: '**Verified source, with its conditions of application:**',
        intro: 'The Royal Decree of 22 April 2019 concerns extraordinary expenses, not a general category of "fixed costs". The consulted provision contains the following conditions:',
        facts: 'The label "school care" alone does not establish how these conditions apply to your situation. Check the child’s age and the agreement or court decision. This source does not justify a general yes/no conclusion without those facts.'
      }
    }.transform_values(&:freeze).freeze
  end
end
