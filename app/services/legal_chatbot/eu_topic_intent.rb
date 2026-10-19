# frozen_string_literal: true

module LegalChatbot
  # A bounded search plan, never evidence that a rule applies to the user's
  # facts. The identities select verified corpus units; no text, source URL,
  # current legal conclusion or user fact is generated here.
  class EuTopicIntent
    GDPR = '32016R0679'
    GDPR_TOPICS = %i[data_erasure direct_marketing_objection data_processor third_country_transfer].freeze

    PLANS = {
      data_erasure: {
        legislation_targets: %w[17 12 19 18].map { |number| [GDPR, number] },
        case_targets: [], discovery_terms: ['data protection', 'privacy']
      },
      direct_marketing_objection: {
        legislation_targets: %w[21 6 14 15 12].map { |number| [GDPR, number] },
        case_targets: [], discovery_terms: ['data protection', 'privacy']
      },
      data_processor: {
        legislation_targets: %w[28 32 4 29].map { |number| [GDPR, number] },
        case_targets: [], discovery_terms: ['data protection', 'privacy']
      },
      cookie_consent: {
        legislation_targets: [%w[32002L0058 5], [GDPR, '7'], [GDPR, '4']],
        case_targets: [{ celex: '62017CJ0673', kind: 'final', number: '' }],
        discovery_terms: ['cookies', 'data protection', 'privacy']
      },
      consumer_withdrawal: {
        legislation_targets: %w[9 16 13 14 10].map { |number| ['32011L0083', number] },
        case_targets: [], discovery_terms: ['consumer rights', 'withdrawal']
      },
      working_time: {
        legislation_targets: %w[6 3 5 17 16].map { |number| ['32003L0088', number] },
        case_targets: [], discovery_terms: ['working time', 'employment']
      },
      ai_prohibited_practices: {
        legislation_targets: %w[5 113 3].map { |number| ['32024R1689', number] },
        case_targets: [], discovery_terms: ['artificial intelligence']
      },
      platform_redress: {
        # Articles 17, 19, 20 and 21 govern the user-facing moderation and
        # redress route; Article 53 is a bounded regulatory complement. Article
        # 93 is included only as the operative rule for entry into force,
        # general application and its own early exceptions. It must not be
        # replaced by an edition date or used as a shortcut to a legal-date
        # conclusion when its verified text is unavailable.
        legislation_targets: %w[20 19 17 21 53 93].map { |number| ['32022R2065', number] },
        case_targets: [], discovery_terms: ['digital services']
      },
      # Regulation 2015/848: which Member State opens the proceedings (Art. 3,
      # with the establishment of Art. 2), which law governs them (Art. 7),
      # their recognition (Art. 19) and secondary proceedings (Art. 34).
      cross_border_insolvency: {
        legislation_targets: %w[3 2 7 19 34].map { |number| ['32015R0848', number] },
        case_targets: [], discovery_terms: ['insolvency']
      },
      flight_disruption: {
        # Scope and compensation take the smallest budgets; exceptions,
        # delay activation, reimbursement/rerouting and care follow. These
        # identities establish neither applicability nor entitlement alone.
        legislation_targets: %w[3 7 5 6 8 9].map { |number| ['32004R0261', number] },
        # Operative holdings only. Missing corpus units remain unavailable;
        # the plan cannot substitute quoted-law paragraphs or another case.
        case_targets: [{ celex: '62007CJ0402', kind: 'final', number: '' },
                       { celex: '62011CJ0011', kind: 'final', number: '' }],
        discovery_terms: ['air passenger rights']
      },
      third_country_transfer: {
        legislation_targets: %w[44 45 46 49 48].map { |number| [GDPR, number] },
        # This judgment is a historical transfer authority, not proof of a
        # country's current adequacy status. It is selected only for a transfer.
        case_targets: [{ celex: '62018CJ0311', kind: 'final', number: '' }],
        discovery_terms: ['data protection', 'privacy']
      }
    }.each_value do |definition|
      definition[:legislation_targets].each(&:freeze).freeze
      definition[:case_targets].each(&:freeze).freeze
      definition[:discovery_terms].freeze
      definition.freeze
    end.freeze

    DATA_CONTEXT = /(?<![[:alpha:]])(?:avg|gdpr|rgpd|dsgvo|persoonsgegevens|persoonlijke gegevens|personal (?:data|information)|donnees? (?:a caractere )?personnelles?|personenbezogen\p{L}* daten)(?![[:alpha:]])/u
    ERASURE = /(?<![[:alpha:]])(?:wis(?:sen|sing)?|gewist|verwijder\p{L}*|vergeten te worden|recht op vergetelheid|eras(?:e|ure|ing)|delet(?:e|ion|ing|ed)|right to be forgotten|effac\p{L}*|supprim\p{L}*|droit a l'oubli|losch\p{L}*|geloscht|recht auf vergessen\p{L}*)(?![[:alpha:]])/u
    MARKETING = /(?<![[:alpha:]])(?:direct(?:e)? marketing|directmarketing|directe reclame|marketing direct|prospection (?:commerciale|directe)|direktwerbung|direktmarketing)(?![[:alpha:]])/u
    MARKETING_OBJECTION = /(?<![[:alpha:]])(?:bezwaar|verzet|stop\p{L}*|afmeld\p{L}*|uitschrijv\p{L}*|uitschrijven|object\p{L}*|oppose|opt out|unsubscrib\p{L}*|refus\p{L}*|oppos\p{L}*|desinscri\p{L}*|widerspr\p{L}*|widerspruch|ablehn\p{L}*|abbestell\p{L}*)(?![[:alpha:]])/u
    PROCESSOR_AGREEMENT = /(?<![[:alpha:]])(?:verwerkersovereenkomst(?:en)?|gegevensverwerkersovereenkomst(?:en)?|data processing (?:agreement|contract)s?|auftragsverarbeitungsvertrag\p{L}*|auftragsverarbeitungsvereinbarung\p{L}*|contrat de traitement (?:des? )?donnees)(?![[:alpha:]])/u
    PROCESSOR = /(?<![[:alpha:]])(?:verwerker(?:s)?|gegevensverwerker(?:s)?|subverwerker(?:s)?|data processors?|processors?|sous traitants?|auftragsverarbeiter\p{L}*|auftragsverarbeitung)(?![[:alpha:]])/u
    COOKIES_OR_TERMINAL_STORAGE = /(?<![[:alpha:]])(?:cookies?|cookiebanner|cookietoestemming|cookie consent|cookie einwilligung|terminal (?:equipment|storage)|terminalapparatuur|eindapparatuur|stockage (?:sur|dans) (?:un |le |mon )?terminal|speicherung (?:auf|in) (?:einem |dem )?endgerat\p{L}*)(?![[:alpha:]])/u
    CONSENT = /(?<![[:alpha:]])(?:cookietoestemming|toestemm\p{L}*|consent\p{L}*|einwillig\p{L}*|zustimm\p{L}*|opt in|refus\p{L}*|weigeren|weiger\p{L}*|reject\p{L}*|ablehn\p{L}*)(?![[:alpha:]])/u
    WITHDRAWAL = /(?<![[:alpha:]])(?:herroep\p{L}*|bedenktijd|retourner\p{L}*|retour|terugstur\p{L}*|terugsturen|teruggev\p{L}*|withdraw\p{L}*|cooling off|return|retract\p{L}*|se retracter|widerruf\p{L}*|widerrufen|zuruckgeb\p{L}*)(?![[:alpha:]])/u
    DISTANCE_PURCHASE = /(?<![[:alpha:]])(?:online|webshop\p{L}*|internet|distance|op afstand|a distance|en ligne|fernabsatz\p{L}*|fernkauf\p{L}*)(?![[:alpha:]])/u
    # These German compounds express both distance and purchase in one word;
    # the separate "online" and "Kauf" boundaries cannot recognise them.
    GERMAN_DISTANCE_PURCHASE = /(?<![[:alpha:]])(?:(?:online|internet)(?:einkauf|kauf)(?:e|en|s)?|(?:online|internet)bestellung(?:en)?|fernkauf(?:e|en|s)?)(?![[:alpha:]])/u
    PURCHASE_OR_CONSUMER = /(?<![[:alpha:]])(?:aankop\p{L}*|aankoop|koop|kopen|gekocht\p{L}*|bestell\p{L}*|consument\p{L}*|consommateur\p{L}*|consumer\p{L}*|verbraucher\p{L}*|purchas\p{L}*|bought|buy|order\p{L}*|achat\p{L}*|achet\p{L}*|commande\p{L}*|einkauf\p{L}*|kauf\p{L}*|gekauft\p{L}*|sale|vente|verkoop)(?![[:alpha:]])/u
    WITHDRAWAL_EXCLUDED_SCOPE = /(?<![[:alpha:]])(?:b2b|business to business|business purchase|company purchase|(?:my|our) (?:business|company)|for business|zakelijk\p{L}* (?:online )?(?:aankoop|bestelling|koop|contract)|(?:mijn|ons|onze) (?:bedrijf|onderneming)|tussen bedrijven|entre (?:professionnels|entreprises|societes)|achat professionnel|(?:mon|notre) entreprise|(?:gewerblich|geschaftlich)\p{L}* (?:(?:online|internet|fern) ?)?(?:einkauf|kauf|bestellung)\p{L}*|(?:mein|unser) unternehmen|meine firma|versicherung\p{L}*|verzeker\p{L}*|insurance|assurance\p{L}*|financial (?:services?|contracts?)|financiel\p{L}* (?:dienst\p{L}*|contract\p{L}*)|services? financiers?|finanzdienstleistung\p{L}*|credit agreement|kredietovereenkomst\p{L}*|kreditvertrag\p{L}*|loan|lening\p{L}*|darlehen\p{L}*|mortgage\p{L}*|hypothe\p{L}*|pret bancaire)(?![[:alpha:]])/u
    WORK = /(?<![[:alpha:]])(?:werk|werken|werkgever\p{L}*|werknemer\p{L}*|arbeid\p{L}*|work|working|workweek|employees?|employers?|travail\p{L}*|salarie\p{L}*|arbeit\p{L}*)(?![[:alpha:]])/u
    HOURS_OR_REST = /(?<![[:alpha:]])(?:uren|uur|arbeidstijd\p{L}*|werkuren|rust|rusttijd\p{L}*|hours?|working time|rest|rest periods?|heures?|temps de travail|repos|stunden|arbeitszeit\p{L}*|ruhezeit\p{L}*|ruhe)(?![[:alpha:]])/u
    NON_EMPLOYMENT_WORK = /(?<![[:alpha:]])(?:work out|workout\p{L}*|hobby\p{L}*|batterij\p{L}*|battery|batteries|akku\p{L}*|batterie\p{L}*|vrijwilligerswerk|benevolat)(?![[:alpha:]])/u
    AI = /(?<![[:alpha:]])(?:ai|ki|artificiele intelligentie|artificial intelligence|intelligence artificielle|kunstlich\p{L}* intelligenz)(?![[:alpha:]])/u
    PROHIBITION = /(?<![[:alpha:]])(?:verbod\p{L}*|verbied\p{L}*|verboden|bans?|banned|prohibit\p{L}*|forbidden|interdit\p{L}*|interdic\p{L}*|verbot\p{L}*|verbiet\p{L}*|untersag\p{L}*)(?![[:alpha:]])/u
    PLATFORM = /(?<![[:alpha:]])(?:platform\p{L}*|onlineplatform\p{L}*|plateforme\p{L}*|plattform\p{L}*|sociale media|social media|social (?:network|account)s?|reseaux? socia(?:l|ux)|soziale\p{L}* (?:medien|netzwerk\p{L}*)|facebook|instagram|tiktok|youtube|twitter)(?![[:alpha:]])/u
    PLATFORM_UNIT = /(?<![[:alpha:]])(?:accounts?|platformaccount\p{L}*|content|posts?|profiles?|users?|inhoud|berichten?|profiel\p{L}*|gebruiker\p{L}*|comptes?|contenu\p{L}*|publication\p{L}*|profil\p{L}*|utilisateur\p{L}*|konto|konten|plattformkonto|beitrag\p{L}*|beitrage|inhalt\p{L}*|nutzer\p{L}*)(?![[:alpha:]])/u
    PLATFORM_RESTRICTION = /(?<![[:alpha:]])(?:geblokkeer\p{L}*|blokk(?:eer|er)\p{L}*|geschorst|schorsing|beperk\p{L}*|verwijderd|moderatie|aanvecht\p{L}*|beroep|klacht\p{L}*|block\p{L}*|bans?|banned|suspend\p{L}*|restriction\p{L}*|restricted|removed|deleted|moderation|appeal\p{L}*|complaint\p{L}*|challenge|bloqu\p{L}*|suspendu\p{L}*|supprime\p{L}*|retire\p{L}*|recours|contester|plainte\p{L}*|gesperrt|sperr\p{L}*|suspendiert|entfernt|geloscht|beschwerde\p{L}*|einspruch|anfecht\p{L}*|beschrank\p{L}*)(?![[:alpha:]])/u
    PLATFORM_EXCLUDED_SCOPE = /(?<![[:alpha:]])(?:bank\p{L}*|banc\p{L}*|financ\p{L}*|finanz\p{L}*|investment\p{L}*|investiss\p{L}*|investering\p{L}*|belegging\p{L}*|trading|crypto\p{L}*|assurance\p{L}*|insurance|versicherung\p{L}*|overheid\p{L}*|gemeente\p{L}*|belastingdienst|government\p{L}*|gouvernement\p{L}*|tax authority|public administration|administration publique|administrative account|compte administratif|commune|behorde\p{L}*|verwaltung\p{L}*|digid|itsme|myminfin|perron|railway|train station|wachtwoord|password|mot de passe|passwort|bugs?|storing\p{L}*|technical (?:error|problem)|inlogprobleem\p{L}*|login (?:error|problem)|probleme de connexion|anmeldefehler)(?![[:alpha:]])/u
    TRANSFER = /(?<![[:alpha:]])(?:doorg(?:even|egeven|ifte)|doorstuur\p{L}*|verstuur\p{L}*|overdracht|overdrag\p{L}*|overbreng\p{L}*|transfer\p{L}*|send\p{L}*|sent|export\p{L}*|share|sharing|transmet\p{L}*|transmis\p{L}*|envoy\p{L}*|envoi|ubertrag\p{L}*|ubermittl\p{L}*|ubermittel\p{L}*|senden|gesendet)(?![[:alpha:]])/u
    FOREIGN_DESTINATION = /(?<![[:alpha:]])(?:third countr\p{L}*|derde land\p{L}*|derdeland\p{L}*|pays tiers|drittland\p{L}*|drittstaat\p{L}*|non eu|non eea|buiten (?:de )?(?:eu|eer|europa)|outside (?:the )?(?:eu|eea|european union)|hors (?:de )?(?:l')?(?:ue|eee|union europeenne)|ausserhalb (?:der )?(?:eu|ewr)|usa|u\.s\.|verenigde staten|united states|etats unis|vereinigte\p{L}* staaten|amerika|americ\p{L}*|amerikan\p{L}*|china|chine|india|inde|indien|russia|rusland|russland|russie|uk|united kingdom|verenigd koninkrijk|royaume uni|vereinigtes konigreich|switzerland|zwitserland|suisse|schweiz|canada|japan|japon|brazil|brasil|bresil|australia|australie|australien)(?![[:alpha:]])/u
    # The Insolvency Regulation needs a cross-border cue: a purely Belgian
    # bankruptcy stays with Belgian law (WER Book XX). Without this plan the
    # Dutch question "faillissement ... in meerdere EU-lidstaten" found no unit
    # of 2015/848, whose Dutch text says "insolventieprocedure" (ledger item 32).
    INSOLVENCY = /(?<![[:alpha:]])(?:faillissement\p{L}*|failliet\p{L}*|insolvent\p{L}*|faillite\p{L}*|insolvab\p{L}*|insolvenz\p{L}*|konkurs\p{L}*|bankrupt\p{L}*|insolvency)(?![[:alpha:]])/u
    CROSS_BORDER = /(?<![[:alpha:]])(?:(?:meerdere|verschillende|andere?) (?:eu )?lidsta\p{L}*|eu lidsta\p{L}*|buitenland\p{L}*|grensoverschrijdend\p{L}*|(?:several|multiple|other|another|different) (?:eu )?member states?|cross border|(?:plusieurs|autres?|differents) etats? membres?|etranger\p{L}*|transfrontali\p{L}*|(?:mehreren?|anderen?|verschiedenen?) (?:eu )?mitgliedstaat\p{L}*|ausland\p{L}*|grenzuberschreitend\p{L}*)(?![[:alpha:]])/u
    FLIGHT = /(?<![[:alpha:]])(?:vlucht(?:en|vertraging\p{L}*|annul\p{L}*)?|vliegtuig\p{L}*|flights?|air passengers?|vols?|flug(?:e|en|reise\p{L}*|verspatung\p{L}*|annullierung\p{L}*)?|anschlussflug\p{L}*|fluggast\p{L}*)(?![[:alpha:]])/u
    FLIGHT_DISRUPTION = /(?<![[:alpha:]])(?:vertra[ag]\p{L}*|vertraging\p{L}*|te laat|later (?:aan|in|op)|annul\p{L}*|geannuleerd|instapweigering|geweigerd\p{L}* (?:instap|aan boord)|delay\p{L}*|late|cancel\p{L}*|denied boarding|retard\p{L}*|refus\p{L}* d'embarquement|verspat\p{L}*|gestrichen|ausgefallen|nichtbeforderung|(?:aansluiting|correspondance|anschluss\p{L}*) (?:gemist|manquee?|verpasst)|(?:gemiste?|missed|miss|miste|mis|manque|verpasst)\b.{0,60}\b(?:aansluiting|overstap|connecting flight|connection|correspondance|anschluss\p{L}*))(?![[:alpha:]])/u
    FLIGHT_REMEDY_OR_CONNECTION = /(?<![[:alpha:]])(?:recht(?:en)?|compens\p{L}*|schadevergoeding\p{L}*|claim\p{L}*|terugbetal\p{L}*|verzorging|aansluit\p{L}*|overstap\p{L}*|rights?|refund\p{L}*|reimburse\p{L}*|rerout\p{L}*|connecting flights?|connections?|droits?|indemnis\p{L}*|rembours\p{L}*|correspondance\p{L}*|reachemin\p{L}*|anspruch\p{L}*|rechte|ausgleich\p{L}*|entschadig\p{L}*|erstatt\p{L}*|anschluss\p{L}*)(?![[:alpha:]])/u
    # Keep neighbouring transport and airline employment questions outside
    # this passenger-rights plan, even when they mention a delayed flight.
    FLIGHT_EXCLUDED_SCOPE = /(?<![[:alpha:]])(?:trein\p{L}*|spoorweg\p{L}*|rail\p{L}*|trains?|zug|zuge|bahn\p{L}*|freight|cargo|vracht\p{L}*|goederen\p{L}*|marchandis\p{L}*|fracht\p{L}*|pilots?|piloot|piloten|pilote\p{L}*|employment|arbeidsovereenkomst\p{L}*|werkgever\p{L}*|contrat de travail|salarie\p{L}*|arbeitsvertrag\p{L}*|arbeitgeber\p{L}*|drone\p{L}*|flight simulator)(?![[:alpha:]])/u
    # Case-sensitive abbreviations after a destination preposition avoid
    # interpreting the English pronoun "us" or a "vs" comparison as a country.
    SHORT_FOREIGN_DESTINATION = /\b(?:to|in|naar|aan|vers|aux|en|nach|an)\s+(?:(?:the|a|an|my|our|de|een|mijn|les|un|une|die|den|einen|einem)\s+)?(?:US|VS)\b/

    class << self
      def plan(question)
        raw = question.to_s[0, 6000]
        return nil unless raw.valid_encoding?

        text = raw.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase.gsub('ß', 'ss')
                  .tr('’–—-', "'   ").gsub(/\s+/, ' ')
        matches = []
        data = text.match?(DATA_CONTEXT)
        matches << :data_erasure if data && text.match?(ERASURE)
        matches << :direct_marketing_objection if text.match?(MARKETING) && text.match?(MARKETING_OBJECTION)
        matches << :data_processor if processor_question?(text, data, raw)
        matches << :cookie_consent if text.match?(COOKIES_OR_TERMINAL_STORAGE) && text.match?(CONSENT)
        german_distance_purchase = text.match?(GERMAN_DISTANCE_PURCHASE)
        if text.match?(WITHDRAWAL) && (text.match?(DISTANCE_PURCHASE) || german_distance_purchase) &&
           (text.match?(PURCHASE_OR_CONSUMER) || german_distance_purchase) && !text.match?(WITHDRAWAL_EXCLUDED_SCOPE)
          matches << :consumer_withdrawal
        end
        matches << :working_time if text.match?(WORK) && text.match?(HOURS_OR_REST) && !text.match?(NON_EMPLOYMENT_WORK)
        matches << :ai_prohibited_practices if text.match?(AI) && text.match?(PROHIBITION)
        if text.match?(PLATFORM) && text.match?(PLATFORM_UNIT) && text.match?(PLATFORM_RESTRICTION) && !text.match?(PLATFORM_EXCLUDED_SCOPE)
          matches << :platform_redress
        end
        matches << :cross_border_insolvency if text.match?(INSOLVENCY) && text.match?(CROSS_BORDER)
        matches << :flight_disruption if flight_disruption_question?(text)
        foreign = text.match?(FOREIGN_DESTINATION) || raw.match?(SHORT_FOREIGN_DESTINATION)
        matches << :third_country_transfer if data && text.match?(TRANSFER) && foreign

        # Erasure is the specific requested GDPR right when another GDPR cue
        # merely supplies its context (a processor, marketing or transferred
        # data). Other concurrent topics, including different GDPR questions,
        # are deliberately ambiguous rather than arbitrarily selecting a plan.
        matches.reject! { |topic| GDPR_TOPICS.include?(topic) && topic != :data_erasure } if matches.include?(:data_erasure)
        return nil unless matches.one?

        topic = matches.first
        definition = PLANS.fetch(topic)
        {
          topic: topic,
          legislation_targets: definition[:legislation_targets].map { |pair| pair.map(&:dup) },
          case_targets: definition[:case_targets].map { |target| target.transform_values(&:dup) },
          discovery_terms: definition[:discovery_terms].map(&:dup)
        }
      end

      private

      def flight_disruption_question?(text)
        text.match?(FLIGHT) && text.match?(FLIGHT_DISRUPTION) && text.match?(FLIGHT_REMEDY_OR_CONNECTION) &&
          !text.match?(FLIGHT_EXCLUDED_SCOPE)
      end

      def processor_question?(text, data, raw)
        return true if text.match?(PROCESSOR_AGREEMENT)
        return false unless data && text.match?(PROCESSOR)

        # Reuse the established disambiguation for bare "processor" and
        # "sous-traitant"; the extra data gate excludes technical processors
        # and ordinary construction or business subcontractors.
        LegalFactProvider.gdpr_processor_question?(raw) || text.match?(/\bauftragsverarbeitung\b/)
      end
    end
  end
end
