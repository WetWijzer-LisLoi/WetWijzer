# frozen_string_literal: true

module LegalChatbot
  # A completeness check for applying admitted working-time sources to an
  # ordinary office commute, not a general verifier of employment-law prose.
  # Quotes alone cannot supply the missing factual application. No source
  # lookup, fixed hours threshold or translated quotation is invented here.
  class OfficeCommuteGrounding
    NUMAC = '1971031602'
    VERSION = 1
    CONDITION_CODES = %w[
      office_commute_direct_application office_commute_employer_disposal office_commute_voluntary_vs_requested
      office_commute_not_automatic_overtime office_commute_hr_conditions office_commute_source_citation
      office_commute_railway_staff_misclassification office_commute_automatic_hours_threshold
      office_commute_unauthorized_never_working_time office_commute_resolution_legal_force
    ].freeze

    TRAIN_PATTERN = /\b(?:trein\p{L}*|train\p{L}*|Zug|Bahn|laptop)\b/iu
    OFFICE_PATTERN = /\b(?:kantoor\p{L}*|pendelaar\p{L}*|werknemer\p{L}*|office|commuter\p{L}*|employees?|workers?|bureau|salari[ée]\p{L}*|travailleur\p{L}*|Büro\p{L}*|Pendler\p{L}*|Arbeitnehmer\p{L}*|Beschäftigt\p{L}*|u|jij|je|you|vous|Sie)\b/iu
    DISPOSAL_PATTERN = /\b(?:ter\s+beschikking|beschikbaar|onder\s+gezag)\b.{0,100}\bwerkgever\p{L}*\b|\bwerkgever\p{L}*\b.{0,100}\b(?:ter\s+beschikking|beschikbaar)\b|[àa]\s+(?:la\s+)?disposition\b.{0,100}\bemployeur\p{L}*\b|\bemployer(?:['’]s)?\s+(?:disposal|control|direction)\b|\bat\s+the\s+disposal\b.{0,100}\bemployer\b|\bavailable\b.{0,80}\bemployer\b|\bArbeitgeber\p{L}*\b.{0,100}\b(?:zur\s+Verfügung|verfügbar)\b|\b(?:zur\s+Verfügung|verfügbar)\b.{0,100}\bArbeitgeber\p{L}*\b/imu
    REQUEST_PATTERN = /\b(?:gevraagd|vraagt|opdracht\p{L}*|opgedragen|opdraagt|verlangt|toestemming|toegestaan|goedgekeurd|demand[ée]\p{L}*|autoris\p{L}*|accord|consignes?|requested|requests?|authorized|authorised|permission|assigned|instruct\p{L}*|approved|asks?|asked|beauftragt\p{L}*|angeordnet\p{L}*|genehmigt\p{L}*|erlaubt\p{L}*|Weisung\p{L}*)\b/iu
    VOLUNTARY_PATTERN = /\b(?:vrijwillig\p{L}*|eigen\s+initiatief|eigen\s+beweging|ongevraagd|zelfgekozen|volontaire\p{L}*|propre\s+initiative|initiative\s+personnelle|voluntary|voluntarily|own\s+initiative|on\s+your\s+own|self[-\s]directed|freiwillig\p{L}*|eigener\s+(?:Initiative|Antrieb))\b/iu
    CONDITIONAL_PATTERN = /\b(?:als|indien|of|voor\s+zover|afhankelijk|si|selon|if|whether|depends?|wenn|ob|abhängig)\b/iu
    OVERTIME_PATTERN = /\b(?:overur\p{L}*|overwerk|overtime|heures\s+supplémentaires|Überstunden\p{L}*)\b/iu
    NOT_AUTOMATIC_PATTERN = /\b(?:niet\s+(?:automatisch|zomaar|vanzelfsprekend|per\s+definitie|noodzakelijk)|geen\s+(?:automatis\p{L}*|vanzelfsprekend\p{L}*)|pas\s+(?:automatiquement|forc[ée]ment|n[ée]cessairement)|not\s+(?:automatically|necessarily|by\s+itself)|does\s+not\s+(?:automatically|by\s+itself)|nicht\s+(?:automatisch|zwangsläufig|ohne\s+Weiteres|von\s+selbst))\b/iu
    HR_PATTERN = /\b(?:HR|human\s+resources|personeelsdienst|ressources\s+humaines|service\s+RH|RH|Personalabteilung|werkgever\p{L}*|employers?|employeur\p{L}*|Arbeitgeber\p{L}*)\b/iu
    SCHEDULE_PATTERN = /\b(?:uurrooster\p{L}*|werkrooster\p{L}*|arbeidsrooster\p{L}*|rooster\p{L}*|werkregeling\p{L}*|arbeidsregeling\p{L}*|horaires?\p{L}*|schedules?|work\s+pattern|Dienstplan\p{L}*|Arbeitszeitplan\p{L}*)\b/iu
    COLLECTIVE_PATTERN = /\b(?:CAO|CCT|CBA|collectieve\s+arbeidsovereenkomst\p{L}*|conventions?\s+collectives?|collective\s+(?:bargaining\s+)?agreement\p{L}*|Tarifvertrag\p{L}*|Tarifverträge|Kollektivvertrag\p{L}*)\b/iu
    AUTOMATIC_PATTERN = /\b(?:altijd|automatisch|ieder\p{L}*|elke|automatiquement|toujours|toutes?|every|always|automatically|immer|stets|automatisch|jede\p{L}*)\b/iu
    HOURS_THRESHOLD_PATTERN = /\b(?:boven|vanaf|na|meer\s+dan|above|after|over|au[-\s]del[àa]|d[èe]s|[àa]\s+partir\s+de|über|nach|ab|mehr\s+als)\s+(?:8|9|acht|negen|eight|nine|huit|neuf|neun)\s*(?:uur|uren|hours?|heures?|Stunden)\b/iu
    NEVER_PATTERN = /\b(?:nooit|never|jamais|nie|niemals)\b/iu
    UNAUTHORIZED_PATTERN = /\b(?:zonder\s+(?:toestemming|opdracht)|niet[-\s]?(?:gevraagd|toegestaan)|sans\s+(?:autorisation|accord)|unauthori[sz]ed|unrequested|without\s+permission|ohne\s+(?:Genehmigung|Auftrag)|nicht\s+genehmigt)\b/iu
    WORKING_TIME_PATTERN = /\b(?:arbeidstijd\p{L}*|arbeidsduur|werktijd\p{L}*|temps\s+de\s+travail|working\s+time|Arbeitszeit\p{L}*)\b/iu
    RESOLUTION_PATTERN = /\b(?:resolutie\p{L}*|r[ée]solution\p{L}*|resolution\p{L}*|Entschließung\p{L}*)\b/iu
    NEGATION_PATTERN = /\b(?:geen|niet|pas|non|not|no|kein\p{L}*|nicht)\b/iu

    class << self
      def topic?(question)
        question.to_s.match?(LegislationSearch::OFFICE_COMMUTE_WORK_PATTERN)
      end

      def evidence(sources)
        selected = {}
        Array(sources).each do |source|
          next unless field(source, :numac).to_s == NUMAC
          next unless field(source, :language_id).is_a?(Integer) && [1, 2].include?(field(source, :language_id))
          next if [true, 1, '1'].include?(field(source, :is_abolished))

          number = (field(source, :article_number).presence || field(source, :article_title)).to_s
          match = number.match(/\A\s*(?:Art(?:ikel|icle)?\.?\s*)?(19|29)\.?\s*\z/i)
          next unless match
          next unless canonical_anchor?(source, match[1])

          text = field(source, :article_text, :text, :full_text, :content).to_s
          clauses = extract_clauses(text, match[1])
          selected[match[1]] ||= clauses.merge(source: source) if clauses
        end
        selected if selected.keys.sort == %w[19 29]
      end

      def evaluate(answer, question, sources)
        grounded = topic?(question) && evidence(sources)
        return { applicable: false, missing_conditions: [], version: VERSION } unless grounded

        # Source quotations, code and URL labels are not practical application.
        # Also remove literal source spans copied as unmarked prose: the live
        # defect was a source dump with valid citations, not a citation failure.
        prose = application_prose(answer, grounded)
        missing = []
        missing << 'office_commute_direct_application' unless prose.match?(TRAIN_PATTERN) && prose.match?(OFFICE_PATTERN)
        missing << 'office_commute_employer_disposal' unless prose.match?(DISPOSAL_PATTERN)
        unless prose.match?(REQUEST_PATTERN) && prose.match?(VOLUNTARY_PATTERN) && prose.match?(CONDITIONAL_PATTERN)
          missing << 'office_commute_voluntary_vs_requested'
        end
        unless prose.split(/(?<=[.!?])\s+|\n/).any? { |sentence| sentence.match?(NOT_AUTOMATIC_PATTERN) && sentence.match?(OVERTIME_PATTERN) }
          missing << 'office_commute_not_automatic_overtime'
        end
        unless prose.match?(HR_PATTERN) && prose.match?(SCHEDULE_PATTERN) && prose.match?(COLLECTIVE_PATTERN) && prose.match?(TRAIN_PATTERN)
          missing << 'office_commute_hr_conditions'
        end
        unless %w[19 29].all? { |number| answer.to_s.match?(%r{\[[^\]]+\]\(/laws/#{NUMAC}(?:\?language_id=[12])?#art[-_]#{number}\)}i) }
          missing << 'office_commute_source_citation'
        end

        prose.split(/(?<=[.!?])\s+|\n/).each do |sentence|
          if sentence.match?(LegislationSearch::RAILWAY_EMPLOYMENT_PATTERN) && !negated_role?(sentence)
            missing << 'office_commute_railway_staff_misclassification'
          end
          if sentence.match?(HOURS_THRESHOLD_PATTERN) && sentence.match?(AUTOMATIC_PATTERN) && sentence.match?(OVERTIME_PATTERN) &&
             !sentence.match?(NOT_AUTOMATIC_PATTERN) && !qualified_hours_threshold?(sentence)
            missing << 'office_commute_automatic_hours_threshold'
          end
          if sentence.match?(UNAUTHORIZED_PATTERN) && sentence.match?(NEVER_PATTERN) && sentence.match?(WORKING_TIME_PATTERN) &&
             !denies_absolute_rule?(sentence)
            missing << 'office_commute_unauthorized_never_working_time'
          end
          missing << 'office_commute_resolution_legal_force' if sentence.match?(RESOLUTION_PATTERN) && !resolution_qualification?(sentence)
        end
        { applicable: true, missing_conditions: missing.uniq, version: VERSION }
      end

      def corrective_feedback(missing_conditions, language: 'nl')
        return nil unless Array(missing_conditions).map(&:to_s).intersect?(CONDITION_CODES)

        FEEDBACK_COPY.fetch(language.to_s, FEEDBACK_COPY.fetch('nl'))
      end

      def fallback(question, sources, language: 'nl')
        grounded = topic?(question) && evidence(sources)
        return nil unless grounded

        copy = FALLBACK_COPY.fetch(language.to_s, FALLBACK_COPY.fetch('nl'))
        paragraphs = copy.values_at(:application, :disposal, :overtime, :facts, :policy)
        grounded.each do |number, record|
          record.each do |key, clause|
            next if key == :source

            quote = clause.lines.map { |line| "> #{line.chomp}" }.join("\n")
            paragraphs << "#{quote}\n> — [Art. #{number}](/laws/#{NUMAC}#art-#{number})"
          end
        end
        paragraphs.join("\n\n")
      end

      private

      def extract_clauses(text, number)
        if number == '19'
          definition = text[/\bOnder\s+arbeidsduur\b[\s\S]{0,650}?\bter\s+beschikking\b[^.!?\n]{0,100}\bwerkgever\b[.]?/i] ||
                       text[/\bOn\s+entend\s+par\s+dur[ée]e\s+du\s+travail\b[\s\S]{0,650}?[àa]\s+la\s+disposition\b[^.!?\n]{0,100}\bemployeur\b[.]?/i]
          return nil unless definition

          normal_limit = text[/\b(?:De\s+)?arbeidsduur\s+van\s+de\s+werknemers\b[^.!?\n]{0,600}\b(?:uur|uren)\s+per\s+week[.]?/i] ||
                         text[/\bLa\s+dur[ée]e\s+du\s+travail\b[^.!?\n]{0,600}\bheures?\s+par\s+semaine[.]?/i]
          { definition: definition }.tap { |clauses| clauses[:normal_limit] = normal_limit if normal_limit }
        else
          payment = text[/\bOverwerk\s+wordt\s+betaald\b[\s\S]{0,1000}?\b(?:gewone|normale)\s+loon\b[.]?/i] ||
                    text[/\bLe\s+travail\s+suppl[ée]mentaire\b[\s\S]{0,1000}?\b(?:r[ée]mun[ée]r[ée]|pay[ée])\b[\s\S]{0,500}?\b(?:r[ée]mun[ée]ration|salaire)\s+(?:normal\p{L}*|ordinair\p{L}*)\b[.]?/iu]
          trigger = text[/\(?\b(?:Pour\s+l['’]application\s+(?:du\s+pr[ée]sent|de\s+cet)\s+article|Voor\s+de\s+toepassing\s+van\s+dit\s+artikel|Als\s+overwerk\s+wordt\s+beschouwd|Est\s+[àa]\s+consid[ée]rer\s+comme\s+travail\s+suppl[ée]mentaire)[\s\S]{0,2000}?\b(?:article|artikel)\s+28[.]?/i]
          return nil unless payment && trigger

          { payment: payment, trigger: trigger }
        end
      end

      def application_prose(answer, grounded)
        text = answer.to_s.gsub(/```[\s\S]*?```/, '').gsub(/^[ \t]*>.*$/, '')
        grounded.each_value do |record|
          record.each { |key, clause| text = text.gsub(clause, '') unless key == :source }
        end
        text.gsub(/\[([^\]]+)\]\([^)]+\)/, '\\1').gsub(%r{https?://\S+}, '').gsub(/[*_`]/, '')
      end

      def negated_role?(sentence)
        sentence.match?(/#{NEGATION_PATTERN.source}.{0,65}#{LegislationSearch::RAILWAY_EMPLOYMENT_PATTERN.source}|#{LegislationSearch::RAILWAY_EMPLOYMENT_PATTERN.source}.{0,65}#{NEGATION_PATTERN.source}/imu)
      end

      def denies_absolute_rule?(sentence)
        sentence.match?(/\b(?:geen|niet|no|not|pas|aucune?|kein\p{L}*|nicht)\b.{0,80}\b(?:regel|rule|r[èe]gle|Regel|betekent|means|signifie|bedeutet)\b|\b(?:regel|rule|r[èe]gle|Regel)\b.{0,80}\b(?:niet|not|pas|nicht)\b/iu)
      end

      def qualified_hours_threshold?(sentence)
        sentence.match?(CONDITIONAL_PATTERN) && (sentence.match?(DISPOSAL_PATTERN) || sentence.match?(COLLECTIVE_PATTERN))
      end

      def resolution_qualification?(sentence)
        non_binding = /\b(?:non[-\s]?binding|non[-\s]contraignant\p{L}*|niet[-\s]?bindend\p{L}*|unverbindlich\p{L}*|sans\s+force\s+contraignante)\b/iu
        return true if sentence.match?(non_binding)

        sentence.match?(NEGATION_PATTERN) && sentence.match?(/\b(?:bindend\p{L}*|recht\p{L}*|contraignant\p{L}*|droit\p{L}*|binding|entitlement|statutory|law|Act|loi|wet|Gesetz|Anspruch\p{L}*|verbindlich\p{L}*)\b/iu)
      end

      def canonical_anchor?(source, number)
        anchor = field(source, :article_anchor, :anchor)
        return false if anchor.present? && anchor.to_s != "#art-#{number}"

        link = field(source, :link, :url)
        link.blank? || link.to_s.match?(%r{\A(?:https://(?:wetwijzer|lisloi|gesetzguide|lexlibera)\.be)?/laws/#{NUMAC}(?:\?language_id=[12])?#art-#{number}\z})
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

    FEEDBACK_COPY = {
      'nl' => 'CORRECTIE: pas de aangeleverde Artikelen 19 en 29 toe op gewone kantoormedewerkers die op de trein pendelen. Laptopwerk is niet automatisch betaald overwerk. Bespreek vrijwillig werk tegenover werk dat de werkgever vraagt of toestaat en beoordeel de feitelijke tijd ter beschikking van de werkgever; toestemming alleen is geen volledige juridische toets. Vraag HR naar het daadwerkelijke uurrooster, de toepasselijke CAO en de behandeling van werk tijdens de woon-werkrit. Verwar normale arbeidsduurgrenzen niet met de afzonderlijke voorwaarden voor overwerk. Noem deze pendelaars geen spoorwegpersoneel en maak van een resolutie geen bindend recht. Citeer de aangeleverde Artikelen 19 en 29; verzin geen drempel, citaat of ontbrekend feit.',
      'fr' => 'CORRECTION : appliquez les articles 19 et 29 fournis aux salariés de bureau travaillant dans le train pendant leur trajet. Ce travail ne constitue pas automatiquement des heures supplémentaires payées. Distinguez le travail volontaire du travail demandé ou autorisé et appréciez le temps réellement à la disposition de l’employeur; l’autorisation seule ne suffit pas au contrôle juridique. Demandez aux RH les horaires réels, la convention collective et le traitement du travail pendant le trajet. Ne confondez pas les limites normales avec les conditions distinctes des heures supplémentaires, ni ces salariés avec du personnel ferroviaire. Une résolution ne crée pas à elle seule un droit contraignant. Citez les articles fournis sans inventer de seuil, citation ou fait manquant.',
      'de' => 'KORREKTUR: Wenden Sie die bereitgestellten Artikel 19 und 29 auf Bürobeschäftigte im Zug auf dem Arbeitsweg an. Laptoparbeit ist nicht automatisch bezahlte Überstundenarbeit. Unterscheiden Sie freiwillige von angeordneter oder genehmigter Arbeit und prüfen Sie die tatsächliche Zeit zur Verfügung des Arbeitgebers; eine Genehmigung allein ist nicht die vollständige rechtliche Prüfung. Fragen Sie die Personalabteilung nach Dienstplan, Tarifvertrag und Behandlung der Arbeit im Zug. Verwechseln Sie normale Arbeitszeitgrenzen nicht mit den gesonderten Überstundenbedingungen und Pendler nicht mit Bahnpersonal. Eine Entschließung schafft für sich keinen verbindlichen Anspruch. Zitieren Sie die gelieferten Artikel ohne erfundene Grenze, Zitate oder Tatsachen.',
      'en' => 'CORRECTION: apply supplied Articles 19 and 29 to ordinary office commuters working on the train. Laptop work is not automatically paid overtime. Distinguish voluntary work from requested or authorized work and assess the actual time at the employer’s disposal; permission alone is not the complete legal test. Ask HR about the actual schedule, applicable collective agreement and treatment of work during the commute. Do not equate normal working-time limits with the separate overtime conditions, misclassify commuters as railway staff, or make a resolution a binding entitlement. Cite the supplied Articles 19 and 29 without inventing a threshold, quotation or missing fact.'
    }.freeze

    FALLBACK_COPY = {
      'nl' => {
        application: 'Voor kantoormedewerkers is laptopwerk op de trein tijdens de woon-werkrit niet automatisch betaald overwerk. De vraag gaat over gewone pendelaars, niet over een spoorwegberoep.',
        disposal: 'Art. 19 vereist een beoordeling van de tijd waarin u feitelijk ter beschikking van de werkgever staat. Ga na of de werkgever dit werk vraagt of toestaat, wat u tijdens de rit moet doen en welke afspraken gelden. Vrijwillig werken op eigen initiatief bewijst die voorwaarden niet op zichzelf; het ontbreken van toestemming is evenmin op zichzelf een definitieve uitsluitingsregel.',
        overtime: 'Als de treinuren arbeidstijd zijn, volgt daar nog niet automatisch een overwerktoeslag uit. De normale arbeidsduurgrenzen en de afzonderlijke overwerkvoorwaarden van Art. 29 mogen niet worden gelijkgesteld. De toepasselijke grenzen, lagere grenzen en uitzonderingen moeten met uw concrete werkregeling worden beoordeeld.',
        facts: 'Bespreek met HR het daadwerkelijke uurrooster, de toepasselijke CAO en hoe werk op de trein wordt gevraagd, geregistreerd en behandeld. Laat verduidelijken welke prestaties verwacht of toegestaan zijn. Alleen het in- en uitklokbeleid geeft nog geen volledig antwoord op de juridische vraag.',
        policy: 'Als een resolutie over teletreinwerken wordt aangehaald: dat is beleidscontext, niet op zichzelf een bindend recht op loon of overuren.'
      },
      'fr' => {
        application: 'Pour les salariés de bureau, travailler sur un ordinateur dans le train pendant le trajet ne constitue pas automatiquement des heures supplémentaires payées. Il s’agit ici de salariés faisant la navette, et non d’un métier ferroviaire.',
        disposal: 'L’art. 19 impose d’apprécier le temps réellement à la disposition de l’employeur. Vérifiez si ce travail est demandé ou autorisé, les tâches attendues pendant le trajet et les accords applicables. Le travail volontaire de sa propre initiative ne prouve pas à lui seul ces conditions; l’absence d’autorisation n’est pas non plus, à elle seule, une règle définitive d’exclusion.',
        overtime: 'Si ces heures constituent du temps de travail, une majoration pour heures supplémentaires n’en découle pas automatiquement. Il faut distinguer les limites normales de durée du travail des conditions distinctes de l’art. 29 et vérifier les limites applicables, les limites inférieures et les exceptions dans votre régime concret.',
        facts: 'Demandez aux RH les horaires réels, la convention collective applicable et comment le travail dans le train est demandé, enregistré et traité. Clarifiez les prestations attendues ou autorisées. La seule politique de pointage ne répond pas complètement à la question juridique.',
        policy: 'Si une résolution sur le travail dans le train est citée, elle constitue un contexte politique et non, à elle seule, un droit contraignant à une rémunération ou à des heures supplémentaires.'
      },
      'de' => {
        application: 'Für Bürobeschäftigte ist Laptoparbeit im Zug auf dem Arbeitsweg nicht automatisch bezahlte Überstundenarbeit. Gemeint sind gewöhnliche Pendler und kein Eisenbahnberuf.',
        disposal: 'Art. 19 verlangt die Prüfung der Zeit, in der Sie dem Arbeitgeber tatsächlich zur Verfügung stehen. Prüfen Sie, ob die Arbeit angeordnet oder genehmigt wird, welche Aufgaben während der Fahrt erwartet werden und welche Absprachen gelten. Freiwillige Arbeit aus eigener Initiative beweist diese Bedingungen nicht allein; fehlende Genehmigung ist für sich ebenfalls keine abschließende Ausschlussregel.',
        overtime: 'Wenn die Zugstunden Arbeitszeit sind, folgt daraus nicht automatisch ein Überstundenzuschlag. Normale Arbeitszeitgrenzen und die gesonderten Überstundenbedingungen des Art. 29 sind zu unterscheiden. Prüfen Sie die geltenden und gegebenenfalls niedrigeren Grenzen sowie Ausnahmen anhand der konkreten Arbeitsregelung.',
        facts: 'Fragen Sie die Personalabteilung nach dem tatsächlichen Dienstplan, dem geltenden Tarifvertrag und danach, wie Arbeit im Zug angeordnet, erfasst und behandelt wird. Klären Sie die erwarteten oder genehmigten Aufgaben. Die Zeiterfassung allein beantwortet die rechtliche Frage noch nicht vollständig.',
        policy: 'Wird eine Entschließung zur Arbeit im Zug angeführt, ist sie politischer Kontext und begründet für sich keinen verbindlichen Anspruch auf Lohn oder Überstunden.'
      },
      'en' => {
        application: 'For office commuters, laptop work on the train during the journey to work is not automatically paid overtime. These are ordinary commuters, not a railway occupation.',
        disposal: 'Article 19 requires assessment of the actual time at the employer’s disposal. Check whether the work is requested or authorized, what tasks are expected during the journey and what arrangements apply. Voluntary work on your own initiative does not by itself establish these conditions; lack of permission is not by itself a definitive exclusion rule either.',
        overtime: 'If the train hours are working time, an overtime premium still does not follow automatically. Normal working-time limits and the separate overtime conditions of Article 29 must be distinguished. Check applicable limits, any lower limits and exceptions against the actual working arrangement.',
        facts: 'Ask HR about the actual schedule, applicable collective agreement and how work on the train is requested, recorded and treated. Clarify what work is expected or authorized. The clocking policy alone does not fully answer the legal question.',
        policy: 'If a resolution about working on the train is cited, it is policy context, not by itself a binding entitlement to pay or overtime.'
      }
    }.transform_values(&:freeze).freeze
  end
end
