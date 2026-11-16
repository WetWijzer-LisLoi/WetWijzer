# frozen_string_literal: true

module LegalChatbot
  # A deadline question about contesting "a decision" that names no decision, authority or field ("En Belgique, je
  # veux contester une décision. De combien de jours est-ce que je dispose ?"). Belgian appeal periods depend on the
  # decision and run from its notification, so no period can be given. Sol 2026-11-16 16:49:59Z: the live answer led
  # with several unrelated example regimes and never asked when the decision was notified. This asks the two things
  # that decide the period, and names no regime. A question that names any field or authority goes the ordinary way;
  # where the reader lives ("Ik woon in Brussel") names neither (Sol 18:15:39Z), a regional authority does.
  module GenericDeadlineClarification
    CONTEST = /\b(?:contest\p{L}*|attaqu\p{L}*|recours|appel|r[ée]clamation|opposition|betwist\p{L}*|aanvecht\p{L}*|
                 aan\s+te\s+vechten|beroep|bezwaar|in\s+beroep\s+gaan|challenge|appeal\p{L}*|object\p{L}*|anfecht\p{L}*|
                 Einspruch|Widerspruch|Berufung)\b/ix
    DECISION = /\b(?:d[ée]cision\p{L}*|beslissing\p{L}*|besluit|decision\p{L}*|Entscheidung\p{L}*|Bescheid)\b/i
    DEADLINE = /\b(?:combien\s+de\s+(?:jours|temps|mois|semaines)|d[ée]lai\p{L}*|hoeveel\s+(?:dagen|tijd|weken|maanden)|
                  termijn\p{L}*|binnen\s+welke\s+termijn|how\s+(?:many\s+days|long|much\s+time)|deadline\p{L}*|time\s+limit|
                  wie\s+(?:viele\s+tage|lange)|Frist\p{L}*)\b/ix
    # Any of these names the decision's field or authority; the ordinary search can then find the governing rule.
    FIELD = /\b(?:belasting\p{L}*|aanslag\p{L}*|imp[ôo]t\p{L}*|fisc\p{L}*|tax\p{L}*|steuer\p{L}*|btw|tva|vat|rva|onem|
               werkloos\p{L}*|ch[ôo]mage|ocmw|cpas|leefloon|revenu\s+d['’]int[ée]gration|vonnis|jugement|judgment|
               arrest|arr[êe]t|rechtbank|tribunal|court|cour|hof|rechter|juge|judge|boete\p{L}*|amende\p{L}*|fines?|
               gas|sanction\p{L}*|verkeer\p{L}*|circulation|traffic|pv|proc[eè]s[-\s]verbal|huur\p{L}*|bail|loyer|rent|
               ontslag|licenciement|dismiss\p{L}*|vergunning\p{L}*|permis|permit\p{L}*|stedenbouw\p{L}*|urbanisme|
               omgeving\p{L}*|environnement|ziekenfonds|mutuelle|riziv|inami|pensioen\p{L}*|pension\p{L}*|kinderbijslag|
               groeipakket|allocations?|studie\p{L}*|examen\p{L}*|exams?|universit\p{L}*|hogeschool|[ée]cole|school|
               asiel|asile|asylum|vreemdeling\p{L}*|[ée]tranger\p{L}*|visum|visa|verblijf\p{L}*|s[ée]jour|nationalit\p{L}*|
               onteigening|expropriation|faillissement|faillite|bankrupt\p{L}*|erfenis|succession|echtscheiding|divorce|
               arbeidsongeval|accident\p{L}*|verzeker\p{L}*|assuranc\p{L}*|insuranc\p{L}*|werkgever|employeur|employer|
               gemeente\p{L}*|communes?|communal\p{L}*|municipal\p{L}*|politie|police|parkeer\p{L}*|stationnement|parking|douane|
               customs|registratie|enregistrement|kadaster|cadastre|raad\s+van\s+state|conseil\s+d['’][ée]tat|
               fod|spf|federale\s+overheidsdienst|service\s+public|minist\p{L}*|onderwijs|enseignement|
               (?:vlaams\p{L}*|waals\p{L}*|wallon\p{L}*|brussels\p{L}*|bruxellois\p{L}*|flamand\p{L}*|duitstalig\p{L}*|
               germanophone)\s+(?:overheid|regering|administratie|agentschap|gewest|gemeenschap|gouvernement|
               administration|r[ée]gion|communaut[ée])|
               (?:r[ée]gion|communaut[ée]|gouvernement|administration|service\s+public)\s+(?:wallon\p{L}*|flamand\p{L}*|
               bruxellois\p{L}*|de\s+bruxelles|germanophone|fran[çc]aise)|hoofdstedelijk\p{L}*\s+gewest|
               sociale\s+zekerheid|s[ée]curit[ée]\s+sociale|social\s+security|rsz|onss|zelfstandig\p{L}*|ind[ée]pendant\p{L}*|
               consument\p{L}*|consommat\p{L}*|consumer|webshop|aankoop|achat|purchase|contract\p{L}*|contrat|overeenkomst)\b/ix

    module_function

    def question?(question)
      text = question.to_s.gsub(/[[:space:]]+/, ' ')
      text.match?(CONTEST) && text.match?(DECISION) && text.match?(DEADLINE) && !text.match?(FIELD)
    end

    def message(language)
      case language.to_s
      when 'fr'
        "Le délai pour contester une décision dépend de la décision elle-même et de l'autorité qui l'a prise, et il court en " \
        "général à partir de sa notification. Je ne peux donc pas vous donner un nombre de jours sans savoir :\n\n" \
        "1. de quelle décision il s'agit et qui l'a prise (une administration, une commune, un tribunal, un employeur...) ;\n" \
        "2. quand et comment vous l'avez reçue (date de la lettre, recommandé, e-mail, remise en main propre).\n\n" \
        'La décision elle-même mentionne souvent le recours possible et son délai. Dites-moi ces deux éléments et je cherche la règle applicable.'
      when 'en'
        'The time limit for contesting a decision depends on the decision itself and on the authority that took it, and it ' \
        "usually runs from its notification. So I cannot give a number of days without knowing:\n\n" \
        "1. which decision it is and who took it (an administration, a municipality, a court, an employer...);\n" \
        "2. when and how you received it (date of the letter, registered mail, e-mail, handed over).\n\n" \
        'The decision itself often states the available appeal and its time limit. Tell me these two points and I will look up the applicable rule.'
      when 'de'
        'Die Frist für die Anfechtung einer Entscheidung hängt von der Entscheidung selbst und von der Behörde ab, die sie ' \
        "getroffen hat, und sie läuft in der Regel ab der Zustellung. Ich kann Ihnen deshalb keine Zahl von Tagen nennen, ohne zu wissen:\n\n" \
        "1. um welche Entscheidung es geht und wer sie getroffen hat (eine Verwaltung, eine Gemeinde, ein Gericht, ein Arbeitgeber...);\n" \
        "2. wann und wie Sie sie erhalten haben (Datum des Schreibens, Einschreiben, E-Mail, persönliche Übergabe).\n\n" \
        'Die Entscheidung selbst nennt oft das mögliche Rechtsmittel und seine Frist. Nennen Sie mir diese beiden Punkte, und ich suche die anwendbare Regel.'
      else
        'De termijn om een beslissing aan te vechten hangt af van de beslissing zelf en van de overheid of instantie die ze ' \
        "nam, en loopt meestal vanaf de kennisgeving. Ik kan dus geen aantal dagen geven zonder te weten:\n\n" \
        "1. om welke beslissing het gaat en wie ze nam (een administratie, een gemeente, een rechtbank, een werkgever...);\n" \
        "2. wanneer en hoe u ze ontving (datum van de brief, aangetekend, e-mail, persoonlijk overhandigd).\n\n" \
        'De beslissing vermeldt vaak zelf het mogelijke beroep en de termijn. Geef me die twee gegevens en ik zoek de toepasselijke regel.'
      end
    end
  end
end
