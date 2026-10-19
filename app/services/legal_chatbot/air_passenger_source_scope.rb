# frozen_string_literal: true

module LegalChatbot
  # Passenger disruption and bilateral market-access rules share aviation
  # vocabulary. Keep the latter, and unrelated neighbouring Civil Code
  # provisions, only when the question actually raises their subject.
  module AirPassengerSourceScope
    JUDGMENT_EXTRACT = /\b(?:uittreksel\s+uit\s+arrest|extrait\s+d['’]un\s+arr[êe]t|extract\s+from\s+(?:a\s+)?judgment|auszug\s+aus\s+(?:einem\s+)?urteil)\b/iu
    PASSENGER_DISPUTE = %r{\b(?:261\s*/\s*2004|passagiersverordening|vluchtvertraging|luchtvaartmaatschappij\p{L}*|air\s+(?:passenger|carrier)\p{L}*|compagnie\p{L}*\s+a[ée]rienne\p{L}*|fluggast\p{L}*|fluggesellschaft\p{L}*)\b}iu
    CONSTITUTIONAL_OR_AID_QUERY = /\b(?:grondwettelijk\p{L}*|staatssteun\p{L}*|gemeentelening\p{L}*|constitutional\p{L}*|state\s+aid|aides?\s+d['’][ée]tat|constitutionnel\p{L}*|verfassungs\p{L}*|staatliche\p{L}*\s+beihilf\p{L}*)\b/iu
    BILATERAL_AIR_SERVICE_NUMACS = %w[1999015145 1953122406].freeze
    AVIATION_PATTERN = /\b(?:luchtvaart\p{L}*|luchtverkeer\p{L}*|luchtdiensten?|luchtvervoer\p{L}*|vliegroute\p{L}*|air\s+(?:services?|transport|traffic|routes?)|a[ée]rien\p{L}*|Luft(?:fahrt|verkehr|dienst)\p{L}*)\b/iu
    BILATERAL_SOURCE_PATTERN = /\b(?:bilatera\p{L}*|tussen\s+(?:de\s+)?(?:regering|koninkrijk)|entre\s+(?:le\s+)?(?:gouvernement|royaume)|between\s+(?:the\s+)?(?:government|kingdom)|zwischen\s+(?:der\s+)?(?:Regierung|K[öo]nigreich)|verkeersrechten|traffic\s+rights|droits\s+de\s+trafic|Verkehrsrechte|aangewezen\s+luchtvaartmaatschappij\p{L}*|designated\s+airlines?|entreprises?\s+(?:de\s+transport\s+)?a[ée]rien\p{L}*\s+d[ée]sign[ée]\p{L}*|benannte\p{L}*\s+Luftfahrtunternehmen)\b/iu
    AGREEMENT_TITLE_PATTERN = /\b(?:overeenkomst\p{L}*|verdrag\p{L}*|luchtvaartovereenkomst\p{L}*|luchtvaartverdrag\p{L}*|agreements?|treaty|accord\p{L}*|convention\p{L}*|Abkommen|Vertrag|Luftverkehrsabkommen\p{L}*)\b/iu
    BETWEEN_STATES_TITLE_PATTERN = /\b(?:tussen|between|entre|zwischen)\s+[^.!?;]{1,120}\s+(?:en|and|et|und)\s+[^.!?;]{1,120}/iu
    BELGIAN_STATE_PATTERN = /\b(?:Belgi[ëe]|Belgique|Belgium|Belgien)\b/iu
    MULTILATERAL_LIABILITY_TITLE_PATTERN = /(?=.*\b(?:montreal|montr[ée]al|warsaw|warschau|varsovie)\b)(?=.*\b(?:verdrag\p{L}*|convention\p{L}*|[Üu]bereinkommen)\b)/iu
    BILATERAL_QUERY_PATTERN = /\b(?:bilatera\p{L}*|verkeersrechten|traffic\s+rights|droits\s+de\s+trafic|Verkehrsrechte|aangewezen\s+luchtvaartmaatschappij\p{L}*|designated\s+airlines?|entreprises?\s+(?:de\s+transport\s+)?a[ée]rien\p{L}*\s+d[ée]sign[ée]\p{L}*|benannte\p{L}*\s+Luftfahrtunternehmen|freight|cargo|vracht\p{L}*|marchandis\p{L}*|Fracht\p{L}*)\b/iu
    AIR_AGREEMENT_QUERY_PATTERN = /\b(?:luchtvaartovereenkomst\p{L}*|luchtvaartverdrag\p{L}*|(?:overeenkomst|verdrag)\s+(?:inzake|betreffende)\s+(?:de\s+)?lucht(?:diensten?|vervoer|vaart)|air\s+(?:services?|transport|traffic)\s+(?:agreement|treaty)|(?:agreement|treaty)\s+(?:on|concerning)\s+air\s+(?:services?|transport|traffic)|accord\p{L}*\s+(?:(?:de|sur|concernant|relatif\s+au|relatif\s+aux)\s+)?(?:services?\s+a[ée]riens?|transport\s+a[ée]rien)|Luftverkehrsabkommen\p{L}*)\b/iu
    RAIL_PATTERN = /\b(?:trein\p{L}*|spoorweg\p{L}*|spoorvervoer\p{L}*|NMBS|SNCB|trains?|railway\p{L}*|rail\s+(?:passengers?|transport|tickets?|fares?)|chemins?\s+de\s+fer|ferroviaire\p{L}*|Zug|Z[üu]ge|Bahn\p{L}*|Eisenbahn\p{L}*|Eurostar|Thalys|TGV)\b/iu
    RAIL_TARIFF_PATTERN = /\b(?:tarie[fv]\p{L}*|tariffs?|fares?|tarifs?|Tarife\p{L}*|treinkaart\p{L}*|rail\s+passes?|train\s+passes?|billets?\s+de\s+train|Bahnkarte\p{L}*)\b/iu
    PASSENGER_RIGHTS_PATTERN = /\b(?:rechten|verplichtingen|rights|obligations|droits|Rechte|Pflichten)\b[^.!?;\n]{0,90}\b(?:reizigers?|passengers?|voyageurs?|Fahrg[äa]ste\p{L}*)\b|\b(?:reizigers?|passengers?|voyageurs?|Fahrg[äa]ste\p{L}*)\b[^.!?;\n]{0,90}\b(?:rechten|verplichtingen|rights|obligations|droits|Rechte|Pflichten)\b/iu
    RESIDENTIAL_RENTAL_PATTERN = /\b(?:woninghuur\p{L}*|huurovereenkomst\p{L}*|huurcontract\p{L}*|huurder\p{L}*|verhuurder\p{L}*|residential\s+(?:lease|tenancy)|tenants?|landlords?|bail\p{L}*|locataire\p{L}*|bailleur\p{L}*|Mietvertrag|Wohnraummiete|Mieter\p{L}*|Vermieter\p{L}*)\b/iu
    # These are independent existence checks, not an unanchored chain of
    # lookaheads: a missing term must not rescan the whole article at every
    # character. source_text is already whitespace-normalized below.
    GHG_ACTIVITY_SCHEDULE_PATTERNS = [
      /\b(?:lijst|lists?|listes?|Verzeichnis|Anhang|schedules?)\b/iu,
      /\b(?:activiteiten|activities|activit[ée]\p{L}*|T[äa]tigkeit\p{L}*)\b/iu,
      /\b(?:broeikasgas\p{L}*|greenhouse\s+gas\p{L}*|gaz\s+[àa]\s+effet\s+de\s+serre|Treibhausgas\p{L}*)\b/iu
    ].freeze
    GHG_QUERY_PATTERN = /\b(?:broeikasgas\p{L}*|emissierecht\p{L}*|emissiehandel|Kyoto|greenhouse\s+gas\p{L}*|emissions?\s+trading|carbon\s+allowances?|CO2|gaz\s+[àa]\s+effet\s+de\s+serre|quotas?\s+d['’][ée]mission\p{L}*|Treibhausgas\p{L}*|Emissionshandel|Emissionszertifikat\p{L}*)\b/iu
    CARGO_DOCUMENT_PATTERN = /\b(?:luchtvrachtbrie[fv]\p{L}*|goederen[-\s]?ontvangstbew(?:ijs|ijzen)|air\s*(?:waybills?|consignment\s+notes?)|cargo\s+receipts?|lettres?\s+de\s+transport\s+a[ée]rien|Luftfrachtbrief\p{L}*|document\s+inzake\s+de\s+aard\s+van\s+de\s+goederen|document\s+(?:on|concerning)\s+the\s+nature\s+of\s+(?:the\s+)?goods)\b/iu
    CARGO_FORMALITY_PATTERN = /\b(?:inhoud|beschrijving|bevatten|gewicht|afzender|douane|contents?|description|consignors?|senders?|customs|exp[ée]diteur\p{L}*|douan\p{L}*|contenu|Inhalt|Beschreibung|Absender|Zoll\p{L}*)\b/iu
    # Montreal's own document-compliance unit refers back to cargo Arts. 4-8
    # without repeating "cargo". Require both that specific reference and
    # its documentary non-compliance subject in an air-carriage treaty; a
    # generic invalid-contract provision or passenger Art. 3 is not enough.
    CARGO_DOCUMENT_COMPLIANCE_PATTERN = /\b(?:niet\s+naleven\b[^.!?;]{0,85}\bvoorgeschreven\s+documenten|non[-\s]?compliance\s+with\s+documentary\s+requirements|inobservation\b[^.!?;]{0,100}\bdocuments?|(?:nichtbeachtung|nichteinhaltung)\b[^.!?;]{0,100}\b(?:urkunden|dokument\p{L}*|Formvorschriften))\b/iu
    CARGO_DOCUMENT_ARTICLE_RANGE_PATTERN = /\b(?:artikelen?\s+4\s+tot\s+(?:en\s+met\s+)?8|articles?\s+4\s+(?:to|[àa])\s+8|artikel\s+4\s+bis\s+8)\b/iu
    PASSENGER_OR_BAGGAGE_PATTERN = /\b(?:passagier\p{L}*|bagage\p{L}*|passengers?|baggage|luggage|voyageur\p{L}*|Flugg[äa]st\p{L}*|Reisend\p{L}*|Gep[äa]ck\p{L}*)\b/iu
    CARGO_QUERY_PATTERN = /\b(?:cargo|freight|vracht\p{L}*|goederen\p{L}*|zending\p{L}*|goods|consignment\p{L}*|waybills?|marchandis\p{L}*|Fracht\p{L}*|G[üu]ter\p{L}*)\b/iu
    NOISE_MAP_PATTERN = /\b(?:strategische?\s+geluids(?:belasting)?kaart\p{L}*|strategic\s+noise\s+maps?|cartes?\s+(?:de\s+)?bruit|L[äa]rmkart\p{L}*)\b/iu
    NOISE_INDICATOR_PATTERN = /\b(?:Lden|Lnight|Lday|Levening|geluidsbelastingsindicator\p{L}*|noise\s+indicators?|indicateurs?\s+(?:de\s+)?bruit|L[äa]rmindikator\p{L}*)\b/iu
    NOISE_QUERY_PATTERN = /\b(?:geluid\p{L}*|lawaai\p{L}*|noise|bruit\p{L}*|L[äa]rm\p{L}*|Lden|Lnight|Lday|Levening)\b/iu

    DIGITAL_SOURCE_PATTERN = /\b(?:digitale\s+(?:inhoud|dienst\p{L}*)|digital\s+(?:content|services?)|contenu\p{L}*\s+num[ée]rique\p{L}*|services?\s+num[ée]rique\p{L}*|digitale\p{L}*\s+(?:Inhalte|Dienstleistung\p{L}*))\b/iu
    # An electronic ticket or an app used to book a flight is not itself a
    # contract to supply digital content. Require the digital product/service
    # as a subject, or a distinct complaint about the app itself.
    DIGITAL_QUERY_PATTERN = /\b(?:digitale\s+(?:inhoud|dienst\p{L}*)|digital\s+(?:content|services?)|contenu\p{L}*\s+num[ée]rique\p{L}*|services?\s+num[ée]rique\p{L}*|digitale\p{L}*\s+(?:Inhalte|Dienstleistung\p{L}*)|software|logiciel\p{L}*|streaming\p{L}*|streamdienst\p{L}*|e[-\s]?books?|livres?\s+num[ée]riques?)\b/iu
    APP_DEFECT_PATTERN = /\b(?:app|applicatie|application)\b[^.!?;\n]{0,55}\b(?:defect\p{L}*|werkt\s+niet|does\s+not\s+work|broken|crash\p{L}*|ne\s+fonctionne\s+pas|funktioniert\s+nicht|fehlerhaft\p{L}*)\b/iu
    # Buying the app itself (including a subscription) is distinct from
    # buying tickets through it. Keep purchase wording next to the app as
    # its object; arbitrary intervening words would admit "paid for tickets
    # using an app" again.
    APP_CONTRACT_PATTERN = /
      \b(?:paid\s+for|bought|purchased|kocht|gekocht|betaal\p{L}*\s+voor|achet[ée]\p{L}*|pay[ée]\p{L}*\s+pour|kaufte|bezahl\p{L}*\s+f[üu]r)\s+
      (?:(?:a|an|the|my|een|de|het|mijn|un|une|mon|ma|eine?|die|das|meine?)\s+)?
      (?:(?:new|paid|premium|mobile|nieuwe?|betaalde|payante|nouvelle|kostenpflichtige|neue)\s+)?
      (?:app|applicatie|application)\b
      |\b(?:app|applicatie|application)\s+(?:gekauft|bezahlt|gekocht|betaald|purchased|bought)\b
      |\b(?:app|applicatie|application)[-\s]+(?:subscription|abonnement)\b
    /ixu

    THIRD_PARTY_UNDERTAKING_PATTERN = /\b(?:sterkmaking|sterkmak\p{L}*|porte[-\s]?fort|third[-\s]party\s+undertaking|Versprechen\s+der\s+Leistung\s+eines\s+Dritten)\b/iu
    THIRD_PARTY_QUERY_PATTERN = /\b(?:sterkmaking|sterkmak\p{L}*|porte[-\s]?fort|third[-\s]party\s+undertaking|Versprechen\s+der\s+Leistung\s+eines\s+Dritten|(?:derde|third\s+party|tiers|Dritter)\b[^.!?;\n]{0,55}\b(?:bekrachtig\p{L}*|ratif\p{L}*|ratifizier\p{L}*))\b/iu

    # Book 5's general hierarchy and restitution-order provisions can rank
    # beside Regulation 261/2004 merely because a disrupted journey is a
    # contract. They are useful only if the passenger actually asks for that
    # separate Belgian contract-law issue. A ticket refund alone is not a
    # request about restitution order.
    BELGIAN_CIVIL_CODE_NUMAC = '2022A32058'
    BOOK_FIVE_NEIGHBOUR_ARTICLES = %w[513 5118].freeze
    ARTICLE_5_13_REQUEST_PATTERN = /\b(?:(?:art(?:icle|ikel)?|artikel)\.?\s*)?5\s*[.,]\s*13\b/iu
    ARTICLE_5_118_REQUEST_PATTERN = /\b(?:(?:art(?:icle|ikel)?|artikel)\.?\s*)?5\s*[.,]\s*118\b/iu
    BELGIAN_CONTRACT_SCOPE_QUERY_PATTERN = /
      \b(?:toepassingsgebied|verwijzingen?)\b[^.!?;\n]{0,80}\b(?:burgerlijk\s+wetboek|boek\s*5|belgisch\p{L}*\s+contractenrecht|contractenrecht)\b
      |\b(?:belgisch\p{L}*|belgian|belge|belgisch\p{L}*)\s+(?:contractenrecht|contract\s+law|droit\s+des\s+contrats|vertragsrecht)\b
      |\bdroit\s+belge\s+des\s+contrats\b
      |\balgemene\s+regels?\s+(?:voor|van)\s+contract\p{L}*\b
      |\bgeneral\s+(?:rules?|scope)\s+(?:of|for)\s+contract\p{L}*\b
      |\bchamp\s+d['’]application\s+(?:du\s+)?(?:droit\s+(?:belge\s+)?des\s+)?contrats?\b
      |\bAnwendungsbereich\s+(?:des\s+)?(?:belgischen\s+)?Vertragsrechts\b
      |\bbijzondere\s+overeenkomsten\b
      |\bspecial\s+contracts?\b
      |\bcontrats?\s+sp[ée]ciaux\b
      |\bbesondere\s+Vertr[äa]ge\b
    /ixu
    BELGIAN_RESTITUTION_ORDER_QUERY_PATTERN = /\b(?:volgorde\s+van\s+(?:de\s+)?restitut\p{L}*|restitutievolgorde|wederzijdse\s+restitut\p{L}*|teruggave\s+na\s+(?:nietigheid|ontbinding)|order\s+of\s+restitution|mutual\s+restitution|restitution\s+after\s+(?:nullity|rescission)|ordre\s+des\s+restitut\p{L}*|restitutions?\s+r[ée]ciproques?|restitution\s+apr[èe]s\s+(?:nullit[ée]|r[ée]solution)|Reihenfolge\s+der\s+R[üu]ckgew[äa]hr|gegenseitige\s+R[üu]ckgew[äa]hr|R[üu]ckgew[äa]hr\s+nach\s+(?:Nichtigkeit|R[üu]cktritt))\b/iu

    EU_DIRECTIVE_TRANSPOSITION_PATTERN = /\b(?:omzetting\s+van\s+(?:europese?\s+)?richtlijn\p{L}*|transposition\s+of\s+(?:an?\s+)?(?:eu\s+)?directive\p{L}*|transposition\s+d['’]une?\s+directive\p{L}*|Umsetzung\s+(?:einer\s+)?(?:EU-)?Richtlinie\p{L}*)\b/iu
    EU_INFRINGEMENT_OR_CJEU_PROCEDURE_SOURCE_PATTERN = /\b(?:inbreuk\p{L}*|infringement\p{L}*|manquement\p{L}*|Vertragsverletzung\p{L}*|beroepen?\s+voor\s+het\s+Hof\s+van\s+justitie|(?:appeals?|actions?)\s+before\s+the\s+Court\s+of\s+Justice|recours\s+devant\s+la\s+Cour\s+de\s+justice|(?:Klagen?|Verfahren)\s+vor\s+dem\s+Gerichtshof)\b/iu
    EU_ADMINISTRATIVE_PROCEDURE_QUERY_PATTERN = /\b(?:inbreukprocedure\p{L}*|procedure\p{L}*\s+(?:inzake|voor|over)\s+(?:een\s+)?inbreuk|omzetting\s+van\s+(?:een\s+)?(?:europese?\s+)?richtlijn\p{L}*|(?:Europese\s+Commissie|Hof\s+van\s+Justitie)\b[^.!?;\n]{0,90}\b(?:inbreuk|beroep|procedure\p{L}*)|infringement\s+procedure\p{L}*|transposition\s+of\s+(?:an?\s+)?(?:eu\s+)?directive\p{L}*|(?:European\s+Commission|Court\s+of\s+Justice)\b[^.!?;\n]{0,90}\b(?:infringement|appeal|action|procedure\p{L}*)|proc[ée]dure\s+en\s+manquement\p{L}*|transposition\s+d['’]une?\s+directive\p{L}*|(?:Commission\s+europ[ée]enne|Cour\s+de\s+justice)\b[^.!?;\n]{0,90}\b(?:manquement|recours|proc[ée]dure\p{L}*)|Vertragsverletzungsverfahren\p{L}*|Umsetzung\s+(?:einer\s+)?(?:EU-)?Richtlinie\p{L}*|(?:Europäische\s+Kommission|Gerichtshof)\b[^.!?;\n]{0,90}\b(?:Vertragsverletzung|Klage|Verfahren))\b/iu

    def self.topic?(question)
      EuTopicIntent.plan(question)&.dig(:topic) == :flight_disruption
    end

    def self.source_relevant?(article, question)
      question = question.to_s
      return true unless topic?(question)

      numac = field(article, :numac).to_s
      return true if %i[pinned viewed selected explicit].any? { |key| [true, 1, 'true', '1'].include?(field(article, key)) }
      return true if !numac.empty? && question.downcase.include?(numac.downcase)

      title = [field(article, :law_title), field(article, :title)].compact.join(' ')
      own_text = [field(article, :article_title), field(article, :article_text), field(article, :text), field(article, :content)].compact.join(' ')
      source_text = [title, own_text].join(' ').gsub(/\s+/, ' ')

      # A circular about a Member State's directive-transposition and
      # infringement/CJEU procedure is not passenger-compensation evidence.
      # Keep it if the user deliberately raises that administrative EU-law
      # route alongside the flight dispute.
      administrative_eu_procedure = source_text.match?(EU_DIRECTIVE_TRANSPOSITION_PATTERN) &&
                                    source_text.match?(EU_INFRINGEMENT_OR_CJEU_PROCEDURE_SOURCE_PATTERN)
      return false if administrative_eu_procedure && !question.match?(EU_ADMINISTRATIVE_PROCEDURE_QUERY_PATTERN)

      # Montreal also contains cargo paperwork rules. Classify the own unit,
      # not the treaty as a whole, before preserving passenger liability.
      cargo_document = own_text.match?(CARGO_DOCUMENT_PATTERN) && own_text.match?(CARGO_FORMALITY_PATTERN) &&
                       !own_text.match?(PASSENGER_OR_BAGGAGE_PATTERN)
      cargo_document ||= title.match?(AVIATION_PATTERN) && title.match?(AGREEMENT_TITLE_PATTERN) &&
                         own_text.match?(CARGO_DOCUMENT_COMPLIANCE_PATTERN) && own_text.match?(CARGO_DOCUMENT_ARTICLE_RANGE_PATTERN) &&
                         !own_text.match?(PASSENGER_OR_BAGGAGE_PATTERN)
      return false if cargo_document && !question.match?(CARGO_QUERY_PATTERN) && !question.match?(CARGO_DOCUMENT_PATTERN)

      noise_mapping = source_text.match?(NOISE_MAP_PATTERN) && source_text.match?(NOISE_INDICATOR_PATTERN)
      return false if noise_mapping && !question.match?(NOISE_QUERY_PATTERN)
      return true if title.match?(MULTILATERAL_LIABILITY_TITLE_PATTERN)

      # A published judgment quoting another instrument is not a general
      # passenger-compensation rule. Keep actual passenger disputes and
      # deliberately mixed constitutional/state-aid questions, not a housing
      # aid decision that happens to quote a compensation paragraph.
      if title.match?(JUDGMENT_EXTRACT) && !own_text.match?(PASSENGER_DISPUTE) &&
         !question.match?(CONSTITUTIONAL_OR_AID_QUERY)
        return false
      end

      number = field(article, :article_title).to_s.delete(' .').sub(/\Aart(?:icle|ikel)?/i, '').downcase

      return false if numac == BELGIAN_CIVIL_CODE_NUMAC && BOOK_FIVE_NEIGHBOUR_ARTICLES.include?(number) &&
                      !book_five_neighbour_requested?(number, question)

      # A bilateral title need not spell out "Kingdom" or "Government":
      # the Japan agreement says simply "between Belgium and Japan". Keep
      # that state-to-state title relation separate from the article's body,
      # and preserve the multilateral passenger-liability conventions.
      bilateral_title = title.match?(AVIATION_PATTERN) && title.match?(AGREEMENT_TITLE_PATTERN) &&
                        title.match?(BETWEEN_STATES_TITLE_PATTERN) && title.match?(BELGIAN_STATE_PATTERN)
      bilateral = !title.match?(MULTILATERAL_LIABILITY_TITLE_PATTERN) &&
                  (BILATERAL_AIR_SERVICE_NUMACS.include?(numac) || bilateral_title ||
                   (source_text.match?(AVIATION_PATTERN) && source_text.match?(BILATERAL_SOURCE_PATTERN)))
      return false if bilateral && !question.match?(BILATERAL_QUERY_PATTERN) && !question.match?(AIR_AGREEMENT_QUERY_PATTERN)

      rail_passenger = source_text.match?(RAIL_PATTERN) &&
                       (source_text.match?(RAIL_TARIFF_PATTERN) || source_text.match?(PASSENGER_RIGHTS_PATTERN))
      return false if rail_passenger && !question.match?(RAIL_PATTERN)
      return false if source_text.match?(RESIDENTIAL_RENTAL_PATTERN) && !question.match?(RESIDENTIAL_RENTAL_PATTERN)

      ghg_schedule = GHG_ACTIVITY_SCHEDULE_PATTERNS.all? { |pattern| source_text.match?(pattern) }
      return false if ghg_schedule && !question.match?(GHG_QUERY_PATTERN)

      digital = (numac == '1804032154' && number.start_with?('1701/')) || source_text.match?(DIGITAL_SOURCE_PATTERN)
      return false if digital && !question.match?(DIGITAL_QUERY_PATTERN) &&
                      !question.match?(APP_DEFECT_PATTERN) && !question.match?(APP_CONTRACT_PATTERN)

      undertaking = (numac == '2022A32058' && number == '5106') || own_text.match?(THIRD_PARTY_UNDERTAKING_PATTERN)
      return false if undertaking && !question.match?(THIRD_PARTY_QUERY_PATTERN)

      true
    end

    def self.field(article, key)
      article[key] || article[key.to_s]
    end
    private_class_method :field

    def self.book_five_neighbour_requested?(number, question)
      case number
      when '513'
        question.match?(ARTICLE_5_13_REQUEST_PATTERN) || question.match?(BELGIAN_CONTRACT_SCOPE_QUERY_PATTERN)
      when '5118'
        question.match?(ARTICLE_5_118_REQUEST_PATTERN) || question.match?(BELGIAN_RESTITUTION_ORDER_QUERY_PATTERN)
      else
        false
      end
    end
    private_class_method :book_five_neighbour_requested?
  end
end
