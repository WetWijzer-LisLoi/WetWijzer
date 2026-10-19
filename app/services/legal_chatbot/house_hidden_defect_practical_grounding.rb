# frozen_string_literal: true

module LegalChatbot
  # A bounded check for the practical claims observed in private house-sale
  # answers. It is not a general legal verifier. Recovery uses clauses from
  # this turn's actual sources, never a reconstructed statute or market price.
  class HouseHiddenDefectPracticalGrounding
    VERSION = 1
    CONDITION_CODES = %w[
      house_unsupported_practical_amount house_insurance_coverage_guarantee
      house_unsupported_settlement_prediction house_deadline_report_delay
      house_unsupported_short_time_rule house_blanket_exclusion
      house_fabricated_practical_experience house_unqualified_lawyer_choice
    ].freeze
    SOURCE_BINDINGS = {
      '1641' => '1804032154', '1643' => '1804032154', '1644' => '1804032154',
      '1648' => '1804032154', '446ter' => '1967101053', '156' => '2014011239'
    }.freeze
    # The start and substance must both occur in the exact admitted article.
    # Keeping the original slice preserves punctuation and amendment markers.
    CLAUSE_SIGNATURES = {
      '1641' => [/De verkoper is gehouden tot vrijwaring/i, /verborgen gebreken[\s\S]*gebruik[\s\S]*prijs/i,
                 /Le vendeur est tenu/i, /(?:vices|d[eé]fauts) cach[eé]s[\s\S]*usage[\s\S]*prix/i],
      '1643' => [/Hij moet instaan voor de verborgen gebreken/i, /niet gekend[\s\S]*tenzij[\s\S]*bedongen/i,
                 /Il est tenu des vices cach[eé]s/i, /pas connus[\s\S]*[àa] moins[\s\S]*stipul[eé]/i],
      '1644' => [/In het geval van de artikelen 1641 en 1643/i, /terug te geven[\s\S]*behouden[\s\S]*deskundigen/i,
                 /Dans le cas des articles 1641 et 1643/i, /rendre[\s\S]*garder[\s\S]*experts/i],
      '1648' => [/De rechtsvordering op grond van koopvernietigende gebreken/i, /korte tijd[\s\S]*aard[\s\S]*gebruiken/i,
                 /L['’]action r[eé]sultant des vices r[eé]dhibitoires/i, /bref d[eé]lai[\s\S]*nature[\s\S]*usage/i],
      '446ter' => [/Een beding daaromtrent/i, /uitsluitend[\s\S]*uitslag[\s\S]*verboden/i,
                   /Un pacte sur les honoraires/i, /exclusivement[\s\S]*r[eé]sultat[\s\S]*interdit/i]
    }.transform_values(&:freeze).freeze
    COST_PATTERN = /\b(?:fees?|costs?|rates?|hourly|consultation|expenses?|honoraires?|tarifs?|frais|co[uû]ts?|\p{L}*kosten\p{L}*|tarie(?:f|ven)|uurloon|ereloon\w*|honorare?|geb[uü]hren\w*|stundensatz)\b/i
    DURATION_PATTERN = /\b(?:takes?|lasts?|duration|timelines?|within|months?|years?|weeks?|days?|duurt?|duren|duur|maanden|jaren|weken|dagen|dur[eé]e|dure|mois|ans|ann[eé]es|semaines|jours|dauert|Dauer|Monate\w*|Jahre\w*|Wochen|Tage\w*)\b/i
    INSURANCE_PATTERN = /\b(?:insur\w*|verzeker\w*|rechtsbijstand\w*|assur\w*|Versicher\w*|Rechtsschutz\w*)\b/i
    COVERAGE_CLAIM_PATTERN = /\b(?:must\s+(?:cover|pay|reimburse)|will\s+(?:cover|pay|reimburse)|covers?|pays?|reimburses?|no\s+(?:upfront|out.of.pocket)\s+(?:costs?|payment)|moet\s+(?:betalen|vergoeden|dekken)|zal\s+(?:betalen|vergoeden|dekken)|dekt|vergoedt|geen\s+(?:voorschot|eigen\s+kosten)|doit\s+(?:couvrir|payer|rembourser)|couvre|rembourse|aucune?\s+(?:avance|frais)|muss\s+(?:zahlen|[uü]bernehmen|erstatten)|[uü]bernimmt|erstattet|keine\s+(?:Vorkasse|Vorauszahlung))\b/i
    SETTLEMENT_PATTERN = /\b(?:settle\w*|settlement\w*|amicabl\w*|schikk\w*|minnelijk\w*|r[eè]gl\w*|amiabl\w*|Vergleich\w*|g[uü]tlich\w*)\b/i
    FREQUENCY_PATTERN = /\b(?:most|usually|typically|often|rarely|almost\s+all|meestal|doorgaans|vaak|zelden|de\s+meeste|g[eé]n[eé]ralement|souvent|rarement|la\s+plupart|meist\w*|normalerweise|h[aä]ufig|selten)\b/i
    AGGREGATE_PATTERN = /\b(?:typical\w*|average\w*|market|generally|standard|usual\w*|survey|gemiddeld\w*|markt\w*|gebruikelijk\w*|onderzoek|moyen\w*|march[eé]|habituel\w*|enqu[eê]te|durchschnitt\w*|Markt\w*|[uü]blich\w*|Studie)\b/i
    CASE_SPECIFIC_PATTERN = /\b(?:this\s+(?:case|quote|policy|judgment)|(?:your|written|supplied)\s+(?:(?:fee|lawyer)\s+)?quote|in\s+the\s+(?:case|judgment)|awarded|dit\s+(?:dossier|geval)|deze\s+(?:zaak|offerte|uitspraak)|uw\s+offerte|toegewezen|cette\s+(?:affaire|d[eé]cision)|ce\s+(?:devis|jugement)|votre\s+devis|allou[eé]\w*|dies\w*\s+(?:Fall|Angebot|Urteil)|Ihr\s+Angebot|zugesprochen\w*)\b/i
    REPORT_PATTERN = /\b(?:expert\s+report|technical\s+report|report|expertise|rapport\w*|deskundigen\w*|Gutachten)\b/i
    LEGAL_ACTION_PATTERN = /\b(?:proceedings?|sue|lawsuit|file|legal\s+advice|lawyer|rechtsvordering|procedure|vordering|advocaat|gerechtelijk\w*|action|proc[eé]dure|avocat|Klage|Verfahren|Anwalt|Rechtsanwalt)\b/i
    REPORT_SEQUENCE_PATTERN = /\b(?:as\s+soon\s+as|once|after|until|wait\w*|await\w*|zodra|nadat|wacht\w*|pas\s+als|après|d[eè]s\s+que|attend\w*|sobald|nachdem|erst\s+wenn|wart\w*)\b/i
    EXCLUSION_PATTERN = /\b(?:exclu\w*|exoneratie\w*|uitsluit\w*|uitgesloten|Ausschluss\w*|ausgeschlossen)\b/i
    NONLIABILITY_PATTERN = /\b(?:not\s+liable|no\s+liability|niet\s+(?:aansprakelijk|gehouden)|pas\s+responsable|aucune\s+responsabilit[eé]|nicht\s+haft\w*|keine\s+Haftung)\b/i
    # These are local evidentiary/conditional statements, not a blanket escape
    # for any sentence containing 'not' (the unsafe exclusion itself has it).
    UNCERTAINTY_PATTERN = /\b(?:do\s+not\s+establish|does\s+not\s+establish|cannot\s+(?:infer|predict|confirm|guarantee)|can't\s+(?:infer|predict|confirm|guarantee)|unknown|not\s+guaranteed|whether|ask\s+(?:whether|if)|check\s+(?:whether|if)|may\s+cover|might\s+cover|if\s+(?:your\s+)?policy\s+covers|niet\s+vastgesteld|onbekend|niet\s+gegarandeerd|kan\s+(?:mogelijk\s+)?dekken|of\s+de\s+verzekering|ne\s+permet\w*\s+pas|ne\s+garantit\s+pas|inconnu\w*|si\s+(?:le\s+contrat|la\s+police)|peut\s+couvrir|nicht\s+belegt|unbekannt|nicht\s+garantiert|ob\s+die\s+Versicherung|kann\s+decken)\b/i

    class << self
      def topic?(question)
        question.to_s.match?(LegislationSearch::HOUSE_PURCHASE_HIDDEN_DEFECT_PATTERN)
      end

      def evidence(sources)
        Array(sources).each_with_object({}) do |source, found|
          next if [true, 1, '1'].include?(field(source, :is_abolished))

          article = (field(source, :article_number).presence || field(source, :article_title)).to_s
                    .sub(/\A\s*Art(?:ikel|icle)?\.?\s*/i, '').strip.sub(/\.\z/, '')
          next unless SOURCE_BINDINGS[article] == field(source, :numac).to_s
          next unless canonical_binding?(source, article)

          language_id = field(source, :language_id)
          next unless language_id.is_a?(Integer) && [1, 2].include?(language_id)

          text = field(source, :article_text, :text, :full_text, :content).to_s
          clauses = article == '156' ? insurance_clauses(text, language_id) : statutory_clause(text, article, language_id)
          next if clauses.blank?

          found[article] ||= { source: source, clauses: Array(clauses), link: canonical_link(source, article) }
        end
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) && evidence(sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded && grounded['1641'] && grounded['1648']

        missing = sentences(answer).flat_map do |sentence|
          codes = unsafe_claim_codes(sentence)
          codes.reject { |code| explicitly_supported?(sentence, code, sources) }
        end
        { applicable: true, missing_conditions: missing.uniq, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        codes = Array(missing_conditions).map(&:to_s) & CONDITION_CODES
        return nil if codes.empty?

        "#{FEEDBACK_COPY.fetch(language.to_s, FEEDBACK_COPY.fetch('nl'))} " \
          "[#{codes.join(', ')}]"
      end

      def fallback(question, sources, language: 'nl')
        return nil unless topic?(question)

        grounded = evidence(sources)
        return nil unless grounded['1641'] && grounded['1648']

        copy = FALLBACK_COPY.fetch(language.to_s, nil)
        return nil unless copy

        parts = [copy.fetch(:intro), quoted_section(copy.fetch(:defect), grounded.fetch('1641'), '1641'),
                 quoted_section(copy.fetch(:deadline), grounded.fetch('1648'), '1648')]
        %w[1643 1644 446ter 156].each do |article|
          parts << quoted_section(copy.fetch(article), grounded.fetch(article), article) if grounded[article]
        end
        parts << copy.fetch(:practical)
        parts.join("\n\n")
      end

      private

      def statutory_clause(text, article, language_id)
        signature = CLAUSE_SIGNATURES[article]
        return nil unless signature

        start_pattern, substance = signature[(language_id - 1) * 2, 2]
        match = text.match(start_pattern)
        return nil unless match

        clause = text[match.begin(0)..].split(/(?<=\.)\s|\n/, 2).first.to_s.strip
        clause if clause.length <= 1500 && clause.match?(substance) && clause.end_with?('.')
      end

      def insurance_clauses(text, language_id)
        match = text.match(/(1[°º]\s*[\s\S]+?)\s*(2[°º]\s*[\s\S]+?)(?=\n\s*[-(]|\z)/)
        return nil unless match

        first = match[1].strip
        second = match[2].strip
        procedure = language_id == 1 ? /gerechtelijke, administratieve of arbitrageprocedure[\s\S]*vrij[\s\S]*advocaat/i : /proc[eé]dure judiciaire, administrative ou arbitrale[\s\S]*(?:libre|libert[eé])[\s\S]*avocat/i
        conflict = language_id == 1 ? /belangenconflict met zijn verzekeraar[\s\S]*vrij[\s\S]*advocaat/i : /conflit d['’]int[eé]r[eê]ts[\s\S]*assureur[\s\S]*(?:libre|libert[eé])[\s\S]*avocat/i
        return nil unless first.length <= 2200 && second.length <= 1500 && first.match?(procedure) && second.match?(conflict)

        [first, second]
      end

      def sentences(text)
        text.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1')
            .gsub(/[*_`]/, '').gsub(/^[ \t]*>[ \t]?/, '')
            .split(/(?<=[!?])\s+|\n|(?<=\.)\s+(?=[[:upper:]])|\b(?:but|however|nevertheless|maar|echter|cependant|toutefois|aber|jedoch)\b/i)
            .map(&:strip).reject(&:empty?)
      end

      def unsafe_claim_codes(sentence)
        return [] if sentence.end_with?('?')

        codes = []
        uncertain = sentence.match?(UNCERTAINTY_PATTERN)
        uncertain ||= sentence.match?(/\bneither\b.{0,70}\b(?:establishes|proves|guarantees|promises)\b|\b(?:do|does)\s+not\s+(?:prove|guarantee|promise)\b/i)
        quantitative = quantities(sentence).any? || sentence.match?(/\b(?:few|several|couple\s+of|one|two|three|hundreds|thousands|enkele|verschillende|twee|drie|honderden|duizenden|quelques|plusieurs|deux|trois|centaines|milliers|einige|mehrere|zwei|drei|Hunderte|Tausende)\s+(?:months?|years?|weeks?|days?|euros?|maanden|jaren|weken|dagen|mois|ans|ann[eé]es|semaines|jours|Monate\w*|Jahre\w*|Wochen|Tage\w*)\b/i)
        hypothetical = sentence.match?(/\b(?:if\s+(?:a|your|the)\s+lawyer\s+quotes|your\s+(?:quote|budget)|uw\s+offerte|votre\s+devis|Ihr\s+Angebot)\b/i)
        if quantitative && !uncertain && !hypothetical && (sentence.match?(COST_PATTERN) || sentence.match?(DURATION_PATTERN))
          codes << 'house_unsupported_practical_amount'
        end
        no_upfront_claim = sentence.match?(/\b(?:no\s+(?:upfront|out.of.pocket)\s+(?:costs?|payment)|geen\s+(?:voorschot|eigen\s+kosten)|aucune?\s+avance|keine\s+(?:Vorkasse|Vorauszahlung))\b/i)
        if ((sentence.match?(INSURANCE_PATTERN) && sentence.match?(COVERAGE_CLAIM_PATTERN)) || no_upfront_claim) && !uncertain
          codes << 'house_insurance_coverage_guarantee'
        end
        codes << 'house_unsupported_settlement_prediction' if sentence.match?(SETTLEMENT_PATTERN) && sentence.match?(FREQUENCY_PATTERN) && !uncertain
        if sentence.match?(REPORT_PATTERN) && sentence.match?(LEGAL_ACTION_PATTERN) && sentence.match?(REPORT_SEQUENCE_PATTERN) &&
           !sentence.match?(/\b(?:do\s+not\s+wait|don't\s+wait|without\s+waiting|not\s+wait|wacht\s+niet|niet\s+wachten|ne\s+pas\s+attendre|n['’]attendez\s+pas|sans\s+attendre|nicht\s+warten|warten\s+Sie\s+nicht|ohne\s+zu\s+warten)\b/i)
          codes << 'house_deadline_report_delay'
        end
        if sentence.match?(/\b(?:short\s+time|bref\s+d[eé]lai|korte\s+tijd|kurze\w*\s+Frist)\b/i) &&
           sentence.match?(/\b(?:strict\w*|shorter|commercial|severe|strikt\w*|korter|commerci[eë]l\w*|ernstig\w*|strict\w*|plus\s+court|commercial\w*|grave|streng\w*|k[uü]rzer|gewerblich\w*|schwer\w*)\b/i) && !uncertain
          codes << 'house_unsupported_short_time_rule'
        end
        if sentence.match?(EXCLUSION_PATTERN) && sentence.match?(NONLIABILITY_PATTERN) &&
           !sentence.match?(/\b(?:may|might|depends?|review\w*|assess\w*|validity|mogelijk|beoord\w*|geldigheid|peut|d[eé]pend\w*|examin\w*|validit[eé]|kann|pr[uü]f\w*|Wirksamkeit)\b/i)
          codes << 'house_blanket_exclusion'
        end
        if sentence.match?(/\b(?:in\s+my\s+experience|I\s+(?:have|'ve|personally)\s+(?:handled|helped|used|seen)|uit\s+mijn\s+ervaring|ik\s+heb\s+(?:zelf|veel)|d['’]apr[eè]s\s+mon\s+exp[eé]rience|j['’]ai\s+personnellement|aus\s+meiner\s+Erfahrung|ich\s+habe\s+(?:selbst|viele))\b/i)
          codes << 'house_fabricated_practical_experience'
        end
        if sentence.match?(INSURANCE_PATTERN) && sentence.match?(/\b(?:must|moet|doit|muss)\b/i) &&
           sentence.match?(/\b(?:choose\s+(?:your\s+)?(?:own\s+)?lawyer|choisir\s+(?:librement\s+)?(?:son\s+)?avocat|vrij\w*\s+(?:een\s+)?advocaat\s+(?:kiezen|keuze)|Anwalt\s+frei\s+w[aä]hlen)\b/i) &&
           !sentence.match?(/\b(?:procedure|proceedings?|arbitr\w*|conflict\w*|belangenconflict|Verfahren|Interessenkonflikt)\b/i) && !uncertain
          codes << 'house_unqualified_lawyer_choice'
        end
        codes
      end

      def explicitly_supported?(sentence, code, sources)
        claim = normalized_claim(sentence)
        return false if claim.length < 25

        Array(sources).any? do |source|
          body = field(source, :article_text, :text, :full_text, :content).to_s
          sentences(body).any? do |source_sentence|
            normalized = normalized_claim(source_sentence)
            # Exact source assertions remain usable, including case-specific
            # costs or explicit policy coverage. An arbitrary citation alone
            # is not support for generated practical claims.
            next true if normalized == claim
            next false unless code == 'house_unsupported_practical_amount'

            amounts = quantities(sentence)
            same_subject = sentence.match?(COST_PATTERN) ? source_sentence.match?(COST_PATTERN) : source_sentence.match?(DURATION_PATTERN)
            general_claim = sentence.match?(FREQUENCY_PATTERN) || sentence.match?(AGGREGATE_PATTERN) || !sentence.match?(CASE_SPECIFIC_PATTERN)
            individual_source = source_sentence.match?(CASE_SPECIFIC_PATTERN) || field(source, :ecli).present? ||
                                field(source, :url, :link).to_s.match?(%r{/jurisprudence/}i)
            aggregate_source = source_sentence.match?(FREQUENCY_PATTERN) || source_sentence.match?(AGGREGATE_PATTERN)
            # An individual award/elapsed time/fee quote must not turn into a
            # typical litigation duration or a general market fee estimate.
            next false if general_claim && individual_source && !aggregate_source

            same_subject && amounts.any? && (amounts - quantities(source_sentence)).empty? &&
              !source_sentence.match?(/\b(?:not|no|niet|geen|pas|nicht|kein\w*)\b/i)
          end
        end
      end

      def normalized_claim(text)
        text.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1')
            .sub(/\s*[—–]\s*Art\..*\z/i, '').sub(/\s*Art\.\s*\d+\w*(?:\([^)]*\))?\.?\s*\z/i, '')
            .gsub(/[*_`>“”"]/, '').gsub(/\A\s*[-•]\s*/, '').gsub(/[[:space:]]+/, ' ')
            .strip.sub(/[.;]\z/, '').downcase
      end

      def quantities(text)
        quantities = []
        text.to_s.scan(/([€$£])\s*(\d+(?:[.,]\d+)?)(?:\s*[-–]\s*(\d+(?:[.,]\d+)?))?|(\d+(?:[.,]\d+)?)(?:\s*[-–]\s*(\d+(?:[.,]\d+)?))?\s*(euros?|EUR|dollars?|USD|pounds?|GBP|%|percent|procent|pour\s+cent|Prozent|months?|maanden|mois|Monate\w*|years?|jaren|ans|ann[eé]es|Jahre\w*|weeks?|weken|semaines|Wochen|days?|dagen|jours|Tage\w*)/i) do |currency, first, last, number, range_end, unit|
          unit = currency || unit
          kind = case unit
                 when /\A(?:€|euros?|EUR)\z/i then 'EUR'
                 when /\A(?:\$|dollars?|USD)\z/i then 'USD'
                 when /\A(?:£|pounds?|GBP)\z/i then 'GBP'
                 when /%|percent|procent|pour\s+cent|Prozent/i then '%'
                 when /month|maand|mois|Monat/i then 'month'
                 when /year|jaren|ans|ann[eé]e|Jahr/i then 'year'
                 when /week|weken|semaine|Wochen/i then 'week'
                 else 'day'
                 end
          [first || number, last || range_end].compact.each { |value| quantities << [value.tr(',', '.'), kind] }
        end
        quantities.uniq
      end

      def canonical_binding?(source, article)
        anchor = field(source, :article_anchor, :anchor)
        return false if anchor.present? && anchor.to_s != "#art-#{article}"

        link = field(source, :link, :url)
        link.blank? || link.to_s.match?(%r{\A(?:https://(?:wetwijzer|lisloi|gesetzguide|lexlibera)\.be)?/laws/#{SOURCE_BINDINGS.fetch(article)}(?:\?language_id=[12])?#art-#{article}\z})
      end

      def canonical_link(source, article)
        field(source, :link, :url).presence || "/laws/#{SOURCE_BINDINGS.fetch(article)}#art-#{article}"
      end

      def quoted_section(intro, evidence, article)
        quotations = evidence.fetch(:clauses).map do |clause|
          "#{clause.lines.map { |line| "> #{line.chomp}" }.join("\n")}\n> — [Art. #{article}](#{evidence.fetch(:link)})"
        end
        [intro, *quotations].join("\n\n")
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
      'en' => 'CORRECTION: remove the flagged unsupported house-sale practical claims. Use only the actual supplied clauses. Do not guess fees, timelines, settlement frequency or personal experience. Lawyer choice is not insurance coverage or a promise of payment: distinguish Article 156, 1° (procedure) from 2° (insurer conflict), and request policy/approval/payment confirmation. Article 446ter concerns outcome-only fees, not market prices. Treat any exclusion as requiring review of the actual contract, not automatic non-liability. Seek deadline advice now; do not make an expert report a prerequisite for protective action or invent stricter short-time categories. Rewrite a substantive, conditional answer with the supplied links, without mentioning this correction.',
      'nl' => 'CORRECTIE: verwijder de gemarkeerde onbevestigde praktische uitspraken over de huiskoop. Gebruik de werkelijke bronclausules. Verzin geen tarieven, duur, schikkingsfrequentie of persoonlijke ervaringen. Advocaatkeuze is geen verzekeringsdekking of betalingsgarantie: onderscheid artikel 156, 1° (procedure) en 2° (belangenconflict), en vraag bevestiging van polis, toestemming en betaling. Artikel 446ter betreft uitsluitend resultaatgebonden ereloon, geen marktprijzen. Laat de werkelijke uitsluitingsclausule beoordelen; leid geen automatische niet-aansprakelijkheid af. Vraag nu termijnadvies, wacht niet op het deskundigenrapport voor beschermende stappen en verzin geen strengere categorieën voor de korte tijd. Herschrijf een inhoudelijk, voorwaardelijk antwoord met de bronlinks, zonder deze correctie te noemen.',
      'fr' => 'CORRECTION : retirez les affirmations pratiques non étayées sur la vente immobilière. Utilisez les clauses réellement fournies, sans inventer honoraires, durée, fréquence des règlements ni expérience personnelle. Le libre choix n’est ni une couverture ni une garantie de paiement : distinguez l’article 156, 1° (procédure) et 2° (conflit avec l’assureur), et demandez confirmation de la police, de l’accord et du paiement. L’article 446ter concerne les honoraires exclusivement liés au résultat, pas les prix pratiqués. Faites examiner la clause réelle, sans déduire une absence automatique de responsabilité. Demandez maintenant conseil sur le délai, sans attendre le rapport pour les mesures conservatoires ni inventer des catégories de bref délai plus strictes. Réécrivez une réponse substantielle et conditionnelle avec les liens fournis, sans mentionner cette correction.',
      'de' => 'KORREKTUR: Entfernen Sie die markierten unbelegten praktischen Aussagen zum Hauskauf. Nutzen Sie die tatsächlich bereitgestellten Klauseln; erfinden Sie keine Honorare, Dauer, Vergleichshäufigkeit oder persönlichen Erfahrungen. Anwaltswahl ist weder Deckung noch Zahlungszusage: unterscheiden Sie Artikel 156, 1° (Verfahren) und 2° (Interessenkonflikt), und verlangen Sie Bestätigung von Police, Zustimmung und Zahlung. Artikel 446ter betrifft ausschließlich erfolgsabhängiges Honorar, keine Marktpreise. Lassen Sie die tatsächliche Ausschlussklausel prüfen, statt automatisch fehlende Haftung anzunehmen. Holen Sie jetzt Fristberatung ein; machen Sie das Gutachten nicht zur Voraussetzung für Schutzmaßnahmen und erfinden Sie keine strengeren kurzen Fristen. Schreiben Sie eine substanzielle bedingte Antwort mit den Quellenlinks neu, ohne diese Korrektur zu erwähnen.'
    }.freeze

    FALLBACK_COPY = {
      'en' => {
        intro: 'A hidden-defect claim is worth a prompt, case-specific legal assessment; the reported sewage problem alone does not establish that you will win. Keep the sale deed, disclosures, communications and technical findings for that assessment.',
        defect: 'Ask a property/construction-law lawyer whether the problem meets the actual hidden-defect test:',
        deadline: 'Get deadline advice now, while arranging the inspection. Do not wait for the final expert report before asking what protective steps are needed. The supplied rule specifies a short time depending on the defect and local customs, not a fixed number of days or a litigation-duration estimate. These sources do not establish that insurer notification or an inspection alone preserves the deadline:',
        '1643' => 'The supplied provision combines liability without knowledge of the defect with a conditional contractual stipulation. It does not establish that your deed contains an applicable exclusion. Have the actual wording and its application reviewed; do not assume automatic non-liability:',
        '1644' => 'Where the conditions of the referenced provisions are met, the supplied text describes return of the property for repayment or retention with a price reduction. It is not an automatic remedy just because a leak is confirmed:',
        '446ter' => 'Request a written fee proposal covering the consultation, letters, expert involvement and possible proceedings, including taxes and expenses. The supplied rule prohibits an agreement exclusively linked to the outcome; it does not set hourly rates or prohibit every percentage-based component:',
        '156' => 'Article 156, 1° concerns qualified free choice when a judicial, administrative or arbitration procedure is needed, with the further dispute-resolution wording below. Point 2° concerns a conflict of interest with the insurer. Neither clause by itself establishes coverage of this seller dispute or promises payment of reasonable costs or no upfront payment. Ask the insurer to confirm coverage, exclusions, limits, deductible, prior approval and payment arrangements in writing:',
        practical: 'When vetting a lawyer, ask about relevant hidden-defect experience, conflicts of interest, the documents needed and a staged written fee plan. Ask for a case-specific assessment of evidence, protective steps, negotiation and possible litigation. The cited provisions do not establish market fee figures, a typical settlement/court duration or how often these disputes settle; a single judgment is not a prediction for your case. This is not a personal account or a guarantee of success.'
      },
      'nl' => {
        intro: 'Een mogelijke vordering wegens verborgen gebreken verdient spoedig juridisch onderzoek van uw concrete dossier; het gemelde rioolprobleem alleen bewijst niet dat u zult winnen. Bewaar de verkoopakte, informatie bij de verkoop, berichten en technische bevindingen.',
        defect: 'Vraag een advocaat vastgoed-/bouwrecht of het probleem voldoet aan de werkelijke toets voor verborgen gebreken:',
        deadline: 'Vraag nu termijnadvies, terwijl u de inspectie regelt. Wacht niet op het definitieve deskundigenrapport voordat u vraagt welke beschermende stappen nodig zijn. De bron noemt een korte tijd afhankelijk van het gebrek en de plaatselijke gebruiken, geen vast aantal dagen of procesduur. Uit deze bronnen volgt niet dat een melding aan de verzekeraar of inspectie alleen de termijn veiligstelt:',
        '1643' => 'De bepaling combineert aansprakelijkheid zonder kennis van het gebrek met een voorwaardelijk contractueel beding. Daarmee staat niet vast dat uw akte een toepasselijke uitsluiting bevat. Laat de werkelijke tekst en toepassing beoordelen; neem geen automatische niet-aansprakelijkheid aan:',
        '1644' => 'Als aan de voorwaarden van de genoemde bepalingen is voldaan, beschrijft de bron teruggave met terugbetaling of behoud met prijsvermindering. Een bevestigde lekkage alleen geeft niet automatisch recht op een van die remedies:',
        '446ter' => 'Vraag een schriftelijk kostenvoorstel voor advies, brieven, deskundigen en een mogelijke procedure, inclusief belastingen en kosten. De bron verbiedt een beding dat uitsluitend aan de uitslag is verbonden; zij bepaalt geen uurtarieven en verbiedt niet iedere procentuele component:',
        '156' => 'Artikel 156, 1° betreft de vrije keuze van een gekwalificeerde vertegenwoordiger wanneer een gerechtelijke, administratieve of arbitrageprocedure nodig is, met de verdere geschillenbeslechtingstekst hieronder. Punt 2° betreft een belangenconflict met de verzekeraar. Geen van beide clausules bewijst op zichzelf dekking van dit verkopersgeschil, vergoeding van redelijke kosten of het ontbreken van een voorschot. Vraag schriftelijke bevestiging van dekking, uitsluitingen, limieten, eigen risico, voorafgaande toestemming en betaling:',
        practical: 'Vraag bij de keuze van een advocaat naar ervaring met verborgen gebreken, belangenconflicten, benodigde stukken en een gefaseerd schriftelijk kostenplan. Laat bewijs, beschermende stappen, onderhandelingen en een eventuele procedure concreet beoordelen. Deze bepalingen geven geen marktprijzen, gebruikelijke schikkings-/procesduur of schikkingsfrequentie; één uitspraak voorspelt uw zaak niet. Dit is geen persoonlijk ervaringsverhaal of succesgarantie.'
      },
      'fr' => {
        intro: 'Une éventuelle action pour vice caché mérite rapidement une analyse juridique du dossier ; le problème d’égout décrit ne prouve pas à lui seul que vous gagnerez. Conservez l’acte de vente, les informations communiquées, les échanges et les constatations techniques.',
        defect: 'Demandez à un avocat en droit immobilier/construction si le problème satisfait au critère réellement fourni pour les vices cachés :',
        deadline: 'Demandez maintenant conseil sur le délai, pendant l’organisation de l’inspection. N’attendez pas le rapport définitif avant de demander quelles mesures conservatoires sont nécessaires. La source prévoit un bref délai selon le vice et les usages locaux, pas un nombre fixe de jours ni une durée du procès. Ces sources n’établissent pas qu’une notification à l’assureur ou une inspection suffit à préserver le délai :',
        '1643' => 'La disposition associe la garantie même sans connaissance du vice à une stipulation contractuelle conditionnelle. Elle ne prouve pas que votre acte contient une exclusion applicable. Faites examiner sa rédaction réelle et son application, sans supposer une absence automatique de responsabilité :',
        '1644' => 'Si les conditions des dispositions citées sont réunies, le texte prévoit la restitution avec remboursement ou la conservation avec réduction du prix. La seule confirmation d’une fuite ne rend pas ces remèdes automatiques :',
        '446ter' => 'Demandez un devis écrit pour la consultation, les courriers, l’expertise et une éventuelle procédure, taxes et frais compris. La source interdit un pacte exclusivement lié au résultat ; elle ne fixe pas de tarif horaire et n’interdit pas toute composante proportionnelle :',
        '156' => 'L’article 156, 1° concerne le libre choix d’un représentant qualifié lorsqu’une procédure judiciaire, administrative ou arbitrale est nécessaire, avec les précisions ci-dessous sur les autres modes de règlement. Le point 2° concerne un conflit d’intérêts avec l’assureur. Aucune clause ne démontre à elle seule la couverture de ce litige avec le vendeur, le remboursement des frais raisonnables ou l’absence d’avance. Demandez par écrit la couverture, les exclusions, les plafonds, la franchise, l’accord préalable et les modalités de paiement :',
        practical: 'Pour choisir un avocat, demandez son expérience des vices cachés, les conflits d’intérêts, les pièces nécessaires et un devis écrit par étapes. Faites évaluer concrètement les preuves, les mesures conservatoires, la négociation et une éventuelle procédure. Ces dispositions ne donnent ni prix de marché, ni durée habituelle, ni fréquence des accords ; un seul jugement ne prédit pas votre dossier. Il ne s’agit ni d’un témoignage personnel ni d’une garantie de succès.'
      },
      'de' => {
        intro: 'Ein möglicher Anspruch wegen versteckter Mängel sollte zeitnah anhand Ihres konkreten Falls rechtlich geprüft werden; das beschriebene Abwasserproblem allein beweist keinen Erfolg. Bewahren Sie Kaufurkunde, Verkaufsinformationen, Nachrichten und technische Feststellungen auf.',
        defect: 'Fragen Sie einen Anwalt für Immobilien-/Baurecht, ob das Problem den tatsächlich bereitgestellten Mangelkriterien entspricht:',
        deadline: 'Holen Sie jetzt Fristberatung ein, während die Untersuchung organisiert wird. Warten Sie nicht auf das endgültige Gutachten, bevor Sie nach notwendigen Schutzmaßnahmen fragen. Die Quelle nennt eine kurze Frist abhängig vom Mangel und örtlichen Gepflogenheiten, keine feste Tageszahl oder Prozessdauer. Diese Quellen belegen nicht, dass eine Versicherermeldung oder Untersuchung allein die Frist wahrt:',
        '1643' => 'Die Vorschrift verbindet Haftung auch ohne Kenntnis des Mangels mit einer bedingten vertraglichen Klausel. Sie belegt nicht, dass Ihre Urkunde einen anwendbaren Ausschluss enthält. Lassen Sie den tatsächlichen Wortlaut und seine Anwendung prüfen, statt automatisch fehlende Haftung anzunehmen:',
        '1644' => 'Bei erfüllten Voraussetzungen der genannten Vorschriften beschreibt die Quelle Rückgabe gegen Erstattung oder Behalten mit Preisreduktion. Ein bestätigtes Leck allein begründet diese Rechtsfolgen nicht automatisch:',
        '446ter' => 'Verlangen Sie ein schriftliches Honorarangebot für Beratung, Schreiben, Sachverständige und ein mögliches Verfahren, einschließlich Steuern und Auslagen. Die Quelle verbietet eine ausschließlich erfolgsabhängige Vereinbarung; sie bestimmt keine Stundensätze und verbietet nicht jede prozentuale Komponente:',
        '156' => 'Artikel 156, 1° betrifft die freie Wahl eines qualifizierten Vertreters bei einem erforderlichen Gerichts-, Verwaltungs- oder Schiedsverfahren samt den folgenden weiteren Streitbeilegungsregeln. Nummer 2° betrifft einen Interessenkonflikt mit dem Versicherer. Keine Klausel belegt allein Deckung dieses Verkäuferstreits, Erstattung angemessener Kosten oder fehlende Vorauszahlungen. Fragen Sie schriftlich nach Deckung, Ausschlüssen, Grenzen, Selbstbehalt, vorheriger Zustimmung und Zahlungsabwicklung:',
        practical: 'Fragen Sie bei der Anwaltswahl nach Erfahrung mit versteckten Mängeln, Interessenkonflikten, benötigten Unterlagen und einem schriftlichen stufenweisen Honorarplan. Lassen Sie Beweise, Schutzmaßnahmen, Verhandlungen und ein mögliches Verfahren konkret bewerten. Diese Vorschriften liefern keine Marktpreise, typische Vergleichs-/Prozessdauer oder Vergleichshäufigkeit; ein einzelnes Urteil sagt Ihren Fall nicht voraus. Dies ist weder ein persönlicher Erfahrungsbericht noch eine Erfolgsgarantie.'
      }
    }.transform_values(&:freeze).freeze
  end
end
