# frozen_string_literal: true

module LegalChatbot
  # Recovery for the self-contained follow-up and catalogue questions. A personal application, an amount, or
  # a compound question needs its own analysis. Every sentence requires its provision in the admitted evidence.
  module ProDeoAnswer
    QUESTIONS = [
      'wat is pro deo rechtsbijstand', 'juridische bijstand pro deo', 'wanneer heb ik recht op juridische bijstand (pro deo)',
      'juridische tweedelijnsbijstand', 'heb ik recht op pro deo', 'wat is juridische tweedelijnsbijstand',
      "qu'est-ce que l'aide juridique pro deo", "qu'est-ce que l'assistance juridique pro deo",
      "qu'est-ce que l'assistance juridique de deuxième ligne", 'assistance juridique de deuxième ligne',
      'what is pro deo legal aid', 'legal assistance pro bono', 'am i entitled to legal aid (pro deo)',
      'what is second-line legal assistance', 'what is secondary legal assistance', 'pro-deo-rechtsbeistand'
    ].to_set.freeze

    # Contiguous operative passages from the consolidated NL and FR texts. In 508/1 only the second-line definition
    # is evidence. In 508/13 both the means test and the third-party-payer restriction support the eligibility note.
    PASSAGES = {
      '508/1' => ['2° juridische tweedelijnsbijstand : de juridische bijstand die wordt verleend aan een natuurlijke persoon in de vorm van een omstandig juridisch advies, bijstand al dan niet in het kader van een procedure of bijstand bij een geding met inbegrip van de vertegenwoordiging',
                  "2° aide juridique de deuxième ligne : l'aide juridique accordée à une personne physique sous la forme d'un avis juridique circonstancié ou l'assistance juridique dans le cadre ou non d'une procédure ou l'assistance dans le cadre d'un procès y compris la représentation"],
      '508/13' => ['De juridische tweedelijnsbijstand kan gedeeltelijk of volledig kosteloos zijn voor wie over ontoereikende bestaansmiddelen beschikt en voor de met hen gelijkgestelde personen. De juridische tweedelijnsbijstand wordt niet toegekend als en in de mate dat de begunstigde een beroep kan doen op de tussenkomst van een derde betaler.',
                   "L'aide juridique de deuxième ligne peut être partiellement ou entièrement gratuite pour les personnes dont les moyens d'existence sont insuffisants ou pour les personnes y assimilées. L'aide juridique de deuxième ligne n'est pas accordée si et dans la mesure où le bénéficiaire peut faire appel à l'intervention d'un tiers payant."],
      '508/7' => ['Bij elke balie stelt de Raad van de Orde van Advocaten een bureau voor juridische bijstand in',
                  "Au sein de chaque barreau, le Conseil de l'Ordre des Avocats établit un Bureau d'aide juridique"],
      '664' => ['Rechtsbijstand bestaat erin degenen die niet over de nodige bestaansmiddelen beschikken om de kosten van rechtspleging, zelfs van een buitengerechtelijke rechtspleging, te bestrijden, geheel of ten dele te ontslaan van de betaling',
                "L'assistance judiciaire consiste à dispenser, en tout ou en partie, ceux qui ne disposent pas des moyens d'existence nécessaires pour faire face aux frais d'une procédure"]
    }.freeze

    EXPLANATIONS = {
      'nl' => ['Met een pro-Deoadvocaat krijgt u juridische tweedelijnsbijstand. Die omvat uitvoerig juridisch advies, bijstand binnen of buiten een procedure en vertegenwoordiging in een geding.',
               'De bijstand kan geheel of gedeeltelijk kosteloos zijn voor personen met ontoereikende bestaansmiddelen en wie met hen wordt gelijkgesteld. Ze wordt niet toegekend voor zover een derde betaler kan tussenkomen.',
               'Bij elke balie is er een bureau voor juridische bijstand (BJB).',
               'Rechtsbijstand voor de kosten van een procedure is een afzonderlijke regeling. Wie onvoldoende bestaansmiddelen heeft, kan geheel of gedeeltelijk worden vrijgesteld van die kosten.'],
      'fr' => ['Un avocat pro deo fournit une aide juridique de deuxième ligne. Elle comprend un avis juridique circonstancié, une assistance dans le cadre ou en dehors d’une procédure et la représentation en justice.',
               'L’aide peut être entièrement ou partiellement gratuite pour les personnes dont les moyens d’existence sont insuffisants et pour les personnes assimilées. Elle n’est pas accordée dans la mesure où un tiers payant peut intervenir.',
               'Chaque barreau dispose d’un bureau d’aide juridique (BAJ).',
               'L’assistance judiciaire est un régime distinct. Elle permet aux personnes qui n’ont pas les moyens nécessaires d’être dispensées en tout ou en partie des frais d’une procédure.'],
      'en' => ['A pro deo lawyer provides second-line legal aid. It covers detailed legal advice, assistance in or outside proceedings and representation in court.',
               'Aid can be wholly or partly free for people with insufficient means and those treated as equivalent. It is unavailable to the extent that a third-party payer can cover the assistance.',
               'Each bar association has a legal aid bureau.',
               'Help with procedural costs is a separate form of assistance. People with insufficient means may receive a full or partial exemption from those costs.'],
      'de' => ['Ein Pro-Deo-Anwalt leistet juristischen Beistand der zweiten Linie. Dazu gehören eine eingehende Rechtsberatung, Beistand innerhalb und außerhalb eines Verfahrens und die Vertretung vor Gericht.',
               'Für Personen mit unzureichenden Existenzmitteln und ihnen gleichgestellte Personen kann dieser Beistand ganz oder teilweise kostenlos sein. Er wird nicht gewährt, soweit ein Dritter die Kosten übernehmen kann.',
               'Bei jeder Rechtsanwaltskammer gibt es ein Büro für juristischen Beistand.',
               'Die Befreiung von Verfahrenskosten ist gesondert geregelt. Wer nicht über ausreichende Mittel verfügt, kann ganz oder teilweise von diesen Kosten befreit werden.']
    }.freeze

    module_function

    def simple_question?(question)
      QUESTIONS.include?(GroundingScope.normalize(question).downcase.delete_suffix('?').rstrip)
    end

    # The live drafts either denied that their sources answered the question or treated one specialised court as
    # the general rule. A list of valid citations after an opening refusal is still no explanation.
    def needs_recovery?(answer)
      text = answer.to_s
      return true if %w[508-1 508-13].any? { |number| !text.match?(%r{\]\(/laws/1967101053(?:\?language_id=[12])?#art-#{number}\)}i) }

      lead = text.gsub(/[*_#]/, '').strip.sub(/\A(?:hoofdregel|kernantwoord|antwoord|réponse|answer|antwort)[[:blank:]]*(?::|\r?\n)\s*/i, '')
                 .split(/(?<=[.!?])\s+|\n/, 2).first.to_s
      lead.match?(/\A(?:geen\s+informatie\s+gevonden|de\s+(?:geraadpleegde|aangeleverde)\s+bronnen\s+
                        (?:omschrijven|defini[ëe]ren|bevatten|geven)\b[^.!?]{0,100}?\b(?:niet|geen)\b|
                        aucune\s+information|les\s+sources\s+[^.!?]{0,50}?\bne\s+(?:d[ée]finissent|contiennent)\s+pas|
                        no\s+information\s+(?:was\s+)?found|the\s+(?:available|consulted|provided)\s+sources\s+do\s+not\s+define|
                        keine\s+informationen\s+gefunden|die\s+(?:vorliegenden|bereitgestellten)\s+quellen\s+enthalten\s+keine\s+definition)/ixu)
    end

    def numbers(question)
      LegislationSearch::COURT_COST_AID_PATTERN.match?(question) ? PASSAGES.keys : %w[508/1 508/13 508/7]
    end

    def focus(question, sources)
      return unless simple_question?(question)

      numbers(question).filter_map do |number|
        numac = number == '664' ? '1967101055' : '1967101053'
        sources.find { |row| GroundingScope.legislation_row?(row) && row[:numac] == numac && GroundingScope.unit_number(row[:article_title]) == number }
      end
    end

    def fallback(question, sources, language:)
      copy = EXPLANATIONS[language.to_s]
      return unless copy && simple_question?(question)

      paragraphs = {}
      focus(question, sources).each do |row|
        number = GroundingScope.unit_number(row[:article_title])
        text = CGI.unescapeHTML(row[:article_text]).gsub(%r{<br\s*/?>}i, "\n")
                  .split(/^[[:blank:]]*(?:-{3,}|Wijzigingen|Modifications)[[:blank:]]*$/i, 2).first.to_s
                  .gsub(/\[\d+\s*|\]\d+/, '')
        passage = PASSAGES.fetch(number).fetch(row[:language_id] - 1)
        next unless GroundingScope.normalize(text).downcase.include?(GroundingScope.normalize(passage).downcase)

        paragraphs[number] = "#{copy.fetch(PASSAGES.keys.index(number))} [Art. #{number}](/laws/#{row[:numac]}#art-#{number.tr('/', '-')})"
      end
      paragraphs.values.join("\n\n") if paragraphs.key?('508/1') && paragraphs.key?('508/13')
    end
  end
end
