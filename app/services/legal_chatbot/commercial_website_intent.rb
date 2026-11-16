# frozen_string_literal: true

module LegalChatbot
  # Shared, bounded activation for website-provider compliance retrieval.
  # "Online dienstverlening" does not by itself mean a public electronic
  # counter. Conversely, a technical website question is not a legal checklist.
  # The selected provisions remain actual corpus rows, not a canned answer;
  # consumer provisions must be applied conditionally when the audience is not
  # stated. An explicitly business-only service gets no consumer-law pack.
  module CommercialWebsiteIntent
    WEBSITE_PATTERN = /\b(?:websites?|web\s*sites?|webshops?|webwinkels?|e[-\s]?commerce|onlineshops?|online[-\s]?(?:shop|store)s?|internetshops?|sites?\s+(?:web|internet)|boutiques?\s+en\s+ligne|Onlinehandel|Webauftritt)\b/iu
    ONLINE_SERVICES_PATTERN = /\b(?:online\s+dienst(?:en)?verlening|diensten?\s+(?:online|via\s+(?:een\s+)?(?:website|internet))|online\s+services?|services?\s+en\s+ligne|prestations?\s+(?:de\s+services?\s+)?en\s+ligne|Online[-\s]?Dienstleistungen?|Dienstleistungen?\s+(?:online|über\s+(?:eine\s+)?Website))\b/iu
    REQUIREMENT_PATTERN = /\b(?:juridisch\p{L}*|wettelijk\p{L}*|vereist\p{L}*|vereisten|verplicht\p{L}*|regel\p{L}*|voorwaarden|vermeld\p{L}*|informatie\s*verplicht\p{L}*|privacy|cookies?|herroep\p{L}*|legal|laws?|rules?|requirements?|obligations?|compliance|terms|withdrawal|l[ée]gal\p{L}*|juridi\p{L}*|obligation\p{L}*|exigence\p{L}*|r[èe]gles?|conditions?|mentions?\s+obligatoires?|r[ée]tract\p{L}*|rechtlich\p{L}*|gesetzlich\p{L}*|Anforderung\p{L}*|Pflicht\p{L}*|Vorschrift\p{L}*|Impressum|Datenschutz|Widerruf\p{L}*|AGB)\b/iu
    PUBLIC_PORTAL_PATTERN = /\b(?:overheids(?:website|loket|portaal|dienst)\p{L}*|elektronisch\s+loket|administratieve\s+procedure\p{L}*|gemeenteloket\p{L}*|guichet\s+(?:[ée]lectronique|administratif)|portail\s+(?:administratif|public)|services?\s+publics?|government\s+(?:portal|website|services?)|public\s+administration|administrative\s+procedures?|Beh[öo]rden(?:portal|website|dienst)\p{L}*|Verwaltungsportal|Verwaltungsverfahren\p{L}*)\b/iu
    COMMERCIAL_PATTERN = /\b(?:commerci[eë]l\p{L}*|webshops?|webwinkels?|e[-\s]?commerce|onderneming\p{L}*|verkop\p{L}*|verkoop|klant\p{L}*|consument\p{L}*|B2[BC]|commercial\p{L}*|business\p{L}*|sell\p{L}*|selling|customers?|consumers?|entreprise\p{L}*|vente\p{L}*|vendre|clients?|consommateur\p{L}*|gewerblich\p{L}*|kommerziell\p{L}*|Unternehmen\p{L}*|verkauf\p{L}*|Kunden?|Verbraucher\p{L}*)\b/iu
    BUSINESS_ONLY_PATTERN = /\b(?:uitsluitend|alleen|enkel|exclusively|only|uniquement|exclusivement|ausschlie[ßs]lich|nur)\b.{0,55}\b(?:B2B|bedrijven|ondernemingen|businesses|companies|professionals|entreprises|professionnels|Unternehmen|Gesch[äa]ftskunden)\b|\bB2B[-\s]?(?:only|uitsluitend|alleen|enkel|uniquement|exclusif|ausschlie[ßs]lich)?\b/iu
    CONSUMER_AUDIENCE_PATTERN = /\b(?:B2C|particulier\p{L}*|consument\p{L}*|consumers?|consommateur\p{L}*|Verbraucher\p{L}*)\b/iu
    TECHNICAL_PATTERN = /\b(?:javascript|css|html|responsive|layout|uitlijning|programmer\p{L}*|coding|programming|programmier\p{L}*|webdesign|bug\p{L}*)\b/iu
    QUESTION_PATTERN = /\A(?=.*(?:#{WEBSITE_PATTERN.source}|#{ONLINE_SERVICES_PATTERN.source}))(?=.*#{REQUIREMENT_PATTERN.source}).*\z/imu

    ECONOMIC_CODE = '2013A11134'
    COOKIE_TARGET = %w[2018040581 10/2].freeze
    # These twelve complementary provisions are an indivisible overview pack:
    # provider identity, precontractual/order information, withdrawal AND its
    # exceptions, current online withdrawal function, cookies, electronic
    # contract steps/correction, the distance-contract scope, general provider
    # information, and the electronic-form exclusions. Priorities
    # preserve the essentials even if a real corpus row is temporarily missing.
    OVERVIEW_TARGETS = [
      [ECONOMIC_CODE, 'XII.6'], [ECONOMIC_CODE, 'VI.45'],
      [ECONOMIC_CODE, 'VI.46'], [ECONOMIC_CODE, 'VI.47'],
      [ECONOMIC_CODE, 'VI.53'], COOKIE_TARGET,
      [ECONOMIC_CODE, 'VI.61/2'], [ECONOMIC_CODE, 'XII.7'],
      [ECONOMIC_CODE, 'XII.9'], [ECONOMIC_CODE, 'XII.10'],
      [ECONOMIC_CODE, 'III.74'], [ECONOMIC_CODE, 'VI.61/1']
    ].map(&:freeze).freeze
    BUSINESS_TARGETS = [
      [ECONOMIC_CODE, 'XII.6'], COOKIE_TARGET, [ECONOMIC_CODE, 'XII.7'],
      [ECONOMIC_CODE, 'XII.9'], [ECONOMIC_CODE, 'XII.10'], [ECONOMIC_CODE, 'III.74']
    ].map(&:freeze).freeze
    ALL_ARTICLE_TARGETS = (OVERVIEW_TARGETS + BUSINESS_TARGETS).uniq.freeze

    PUBLIC_DIGITAL_SOURCE_PATTERN = /\b(?:digitale\s+transitie\s+van\s+(?:de\s+)?overheidsinstanties|transition\s+num[ée]rique\s+des\s+autorit[ée]s\s+publiques|digital\s+transition\s+of\s+public\s+authorities|digitale\s+Transformation\s+(?:der\s+)?Beh[öo]rden)\b/iu
    ELECTION_SOURCE_PATTERN = /\b(?:verkiezingsuitslag\p{L}*|r[ée]sultats?\s+[ée]lectora\p{L}*|election\s+results?|Wahlergebnis\p{L}*)\b/iu
    SUBSIDY_DATABASE_SOURCE_PATTERN = /\A(?=.*\b(?:subsid\p{L}*|subvention\p{L}*|grants?|Zusch[üu]ss\p{L}*))(?=.*\b(?:database|databank|base\s+de\s+donn[ée]es|Datenbank)).*\z/imu
    TELECOM_SOURCE_PATTERN = /\b(?:elektronische\s+communicatie|communications?\s+[ée]lectroniques?|electronic\s+communications?|elektronische\s+Kommunikation)\b/iu
    TELECOM_REQUEST_PATTERN = /\b(?:telecom\p{L}*|telefoon\p{L}*|telephone\p{L}*|t[ée]l[ée]phon\p{L}*|Telekommunikation\p{L}*|nationale\s+veiligheid|s[ée]curit[ée]\s+nationale|national\s+security|nationale\s+Sicherheit)\b/iu
    IRRELEVANT_TELECOM_ARTICLES = %w[121/1 127 129].freeze
    PUBLIC_CHANNEL_PROPOSAL_PATTERN = /\b(?:alternatieve\s+niet[-\s]digitale\s+kanalen|canaux\s+alternatifs?\s+non\s+num[ée]riques?|alternative\s+non[-\s]digital\s+channels?|alternative\s+nicht[-\s]digitale\s+Kan[äa]le)\b/iu
    HISTORY_ADVICE_QUERY_PATTERN = /\b(?:wetsvoorstel\p{L}*|voorontwerp\p{L}*|advies|adviezen|avis|drafts?|proposals?|opinions?|history|histoire|histori\p{L}*|geschied\p{L}*|historisch\p{L}*|Gesetzentwurf\p{L}*|Gutachten|Stellungnahme)\b/iu
    WITHDRAWAL_FUNCTION_PATTERN = /\b(?:herroepingsfunctie|fonction\s+de\s+r[ée]tractation|withdrawal\s+function|Widerrufsfunktion)\b/iu
    DRAFT_SOURCE_PATTERN = /\b(?:voorontwerp|wetsontwerp|projet\s+de\s+loi|draft\s+(?:law|bill)|Gesetzentwurf)\b/iu
    WITHDRAWAL_DRAFT_OPINION = 'ECLI:BE:GBAPD:2025:AVIS.20251013.1'
    PHARMACY_OPINION_PATTERN = /\ARVSADV:66\.163(?::[A-Z]{2})?\z/i
    FINANCIAL_SERVICES_DRAFT_OPINION = 'ECLI:BE:GBAPD:2026:AVIS.20260408.2'
    SOURCE_IDENTIFIER_PATTERN = %r{\b(?:ECLI|RVSADV):[[:alnum:].:_/-]+}iu
    PHARMACY_SECTOR_PATTERN = /\b(?:apothe\p{L}*|farmaceu\p{L}*|geneesmiddel\p{L}*|medicijn\p{L}*|medische\s+hulpmiddel\p{L}*|pharmac\p{L}*|medicines?|medicaments?|m[ée]dicaments?|medical\s+devices?|dispositifs?\s+m[ée]dicaux|Arzneimittel\p{L}*|Medikament\p{L}*|Medizinprodukt\p{L}*)\b/iu
    FINANCIAL_SERVICES_SECTOR_PATTERN = /\b(?:financi[ëe]le\s+diensten?|financial\s+services?|services?\s+financiers?|Finanzdienstleistung\p{L}*|verzeker\p{L}*|insuranc\p{L}*|assuranc\p{L}*|Versicher\p{L}*|krediet\p{L}*|credits?|cr[ée]dits?|Kredit\p{L}*|lening\p{L}*|loans?|pr[êe]ts?|Darlehen\p{L}*|gepersonaliseerd\p{L}*\s+prij\p{L}*|personali[sz]ed\s+pric\p{L}*|prix\s+personnalis[ée]\p{L}*|personalisierte\p{L}*\s+Preis\p{L}*)\b/iu

    # A consumer exercising a right against a webshop ("Je zei dat ik de webshop vóór het verstrijken van de termijn
    # moet verwittigen. Welk artikel regelt die kennisgeving?") is not a website provider asking what the site must
    # comply with: that question got the provider pack and its fixed AVG Arts. 6, 13 and 32 (Sol 2026-11-16
    # 16:49:59Z). A question about the reader's own site stays a provider question.
    CONSUMER_EXERCISE_PATTERN = /\b(?:verwittig\p{L}*|kennisgev\p{L}*|meedel\p{L}*|terugsturen|terugzenden|terugbetal\p{L}*|herroepen|retourner|renvoyer|rembours\p{L}*|me\s+r[ée]tracter|(?:informer|pr[ée]venir|avertir)\s+(?:le|la|l['’])\s*(?:vendeur|boutique|commer[çc]ant|site|entreprise)|(?:ma|mon)\s+(?:r[ée]tractation|droit\s+de\s+r[ée]tractation)|send\s+(?:it\s+)?back|refund|zur[üu]cksenden|Erstattung)\b/iu
    CONSUMER_PERSPECTIVE_PATTERN = /\b(?:ik|mij|mijn\s+(?:aankoop|bestelling|pakket|geld)|je\s+zei|als\s+consument|j['’]ai|je\s+(?:dois|veux|peux)|en\s+tant\s+que\s+consommateur|I\s+(?:bought|ordered|must|want)|as\s+a\s+consumer|ich\s+(?:habe|muss|will)|als\s+Verbraucher)\b/iu
    PROVIDER_PERSPECTIVE_PATTERN = /\b(?:(?:mijn|onze|ma|notre|mon|my|our|meine?|unsere?)\s+(?:eigen\s+)?(?:webshop|webwinkel|website|site|boutique|shop|Onlineshop|klant\p{L}*|client\p{L}*|customers?|Kunden)|ik\s+verkoop|wij\s+verkopen|je\s+vends|nous\s+vendons|I\s+sell|we\s+sell|ich\s+verkaufe|als\s+(?:verkoper|webshop|handelaar|uitbater)|en\s+tant\s+que\s+(?:vendeur|commer[çc]ant)|as\s+a\s+(?:seller|trader)|ik\s+(?:beheer|run|baat|heb\s+een\s+(?:webshop|webwinkel))|beheer\s+(?:een|mijn|onze)\s+(?:webshop|webwinkel|website)|je\s+(?:g[èe]re|exploite|tiens)|I\s+(?:run|manage|operate|own)|ich\s+(?:betreibe|f[üu]hre)|(?:een|de|mijn)\s+klant(?:en)?\s+(?:moet|te|verwittig\p{L}*|informer\p{L}*)|(?:un|mes|nos)\s+clients?\s+(?:doit|dois|pr[ée]venir|informer)|notify\s+(?:a|my|our)\s+customers?)\b/iu
    # The consumer side is a withdrawal, return or refund question; a provider asking how to warn a customer about a
    # data breach is no consumer exercise (Sol 18:15:39Z).
    CONSUMER_RIGHT_CONTEXT_PATTERN = /\b(?:herroep\p{L}*|terugsturen|terugzenden|retour\p{L}*|bedenktijd|terugbetal\p{L}*|termijn|r[ée]tract\p{L}*|rembours\p{L}*|renvoyer|d[ée]lai|withdraw\p{L}*|refund\p{L}*|send\s+(?:it\s+)?back|cooling[-\s]off|Widerruf\p{L}*|R[üu]cksend\p{L}*|Erstattung)\b/iu

    def self.topic?(question)
      text = normalized(question)
      return false unless text.match?(QUESTION_PATTERN)
      return false if text.match?(TECHNICAL_PATTERN) && !text.match?(COMMERCIAL_PATTERN)
      return false if text.match?(PUBLIC_PORTAL_PATTERN) && !text.match?(COMMERCIAL_PATTERN)
      return false if consumer_exercise?(text)

      true
    end

    # Privacy duties of whoever runs the site are never a consumer exercise, whatever deadline words they carry (Sol
    # 19:02:40Z: a data protection officer asking "binnen welke termijn ik een datalek moet meedelen" for a webshop).
    PRIVACY_DUTY_PATTERN = /\b(?:datalek\p{L}*|gegevenslek\p{L}*|data\s*breach\p{L}*|fuite\s+de\s+donn[ée]es|violation\s+de\s+donn[ée]es|
                              persoonsgegevens|donn[ée]es\s+personnelles|personal\s+data|privacy|avg|gdpr|rgpd|dsgvo|dpo|
                              functionaris\s+voor\s+gegevensbescherming|d[ée]l[ée]gu[ée]\s+[àa]\s+la\s+protection\s+des\s+donn[ée]es|
                              gegevensbeschermingsautoriteit|autorit[ée]\s+de\s+protection\s+des\s+donn[ée]es|gba|apd|
                              Datenschutz\p{L}*|Datenpanne)\b/ix

    def self.consumer_exercise?(text)
      text.match?(CONSUMER_EXERCISE_PATTERN) && text.match?(CONSUMER_PERSPECTIVE_PATTERN) &&
        text.match?(CONSUMER_RIGHT_CONTEXT_PATTERN) && !text.match?(PROVIDER_PERSPECTIVE_PATTERN) &&
        !text.match?(PRIVACY_DUTY_PATTERN)
    end

    def self.business_only?(question)
      text = normalized(question)
      topic?(text) && text.match?(BUSINESS_ONLY_PATTERN) && !text.match?(CONSUMER_AUDIENCE_PATTERN)
    end

    def self.article_targets(question)
      return [] unless topic?(question)

      business_only?(question) ? BUSINESS_TARGETS : OVERVIEW_TARGETS
    end

    def self.source_relevant?(source, question, context_numacs: [])
      text = normalized(question)
      return true unless topic?(text)
      return true if selected_source?(source, text, context_numacs)

      title = (field(source, :law_title) || field(source, :title)).to_s
      return false if title.match?(PUBLIC_DIGITAL_SOURCE_PATTERN) && !text.match?(PUBLIC_PORTAL_PATTERN)
      return false if title.match?(ELECTION_SOURCE_PATTERN) && !text.match?(ELECTION_SOURCE_PATTERN)
      return false if title.match?(SUBSIDY_DATABASE_SOURCE_PATTERN) && !text.match?(SUBSIDY_DATABASE_SOURCE_PATTERN)

      number = field(source, :article_title).to_s.sub(/\A\s*Art(?:ikel|icle)?\.?\s*/iu, '').delete(' .')
      # Art.129 was repealed: cookie requirements are now 2018040581 Art10/2.
      # Keep only an explicit telecom/security request, never the old cookie
      # article merely because a site uses an electronic communication.
      return false if title.match?(TELECOM_SOURCE_PATTERN) && IRRELEVANT_TELECOM_ARTICLES.include?(number) && !text.match?(TELECOM_REQUEST_PATTERN)

      true
    end

    def self.secondary_source_relevant?(source, question)
      text = normalized(question)
      return true unless topic?(text)
      return true if selected_source?(source, text, [])
      return true if explicit_case_reference?(source, text)
      # "AVIS" inside an ECLI is metadata, not a request for an opinion or
      # history. Explicit exact references above are preserved independently.
      return true if text.gsub(SOURCE_IDENTIFIER_PATTERN, '').match?(HISTORY_ADVICE_QUERY_PATTERN)
      return false unless source_relevant?(source, text)

      title = field(source, :title).to_s
      return false if title.match?(PUBLIC_CHANNEL_PROPOSAL_PATTERN) && !text.match?(PUBLIC_PORTAL_PATTERN)

      # The 2025 APD opinion concerns a pre-enactment draft. The actual new
      # rule is now in consolidated WER VI.61/2; a current checklist should
      # not present that old opinion as its only authority. Preserve explicit
      # references in the search adapters and requested legislative history.
      case_number = field(source, :case_number).to_s
      return false if case_number.upcase == WITHDRAWAL_DRAFT_OPINION

      # These observed neighbours have a specialist subject, not a general
      # website-compliance rule: pharmacy distribution and a financial-services
      # draft respectively. Keep them for that sector, explicitly selected
      # evidence and requested history; do not ban opinions as a source class.
      return text.match?(PHARMACY_SECTOR_PATTERN) if case_number.match?(PHARMACY_OPINION_PATTERN)
      return text.match?(FINANCIAL_SERVICES_SECTOR_PATTERN) if case_number.upcase == FINANCIAL_SERVICES_DRAFT_OPINION

      subject = [title, field(source, :summary)].compact.join(' ')
      if subject.match?(DRAFT_SOURCE_PATTERN)
        pharmacy = subject.match?(PHARMACY_SECTOR_PATTERN)
        financial = subject.match?(FINANCIAL_SERVICES_SECTOR_PATTERN)
        if pharmacy || financial
          return (pharmacy && text.match?(PHARMACY_SECTOR_PATTERN)) ||
                 (financial && text.match?(FINANCIAL_SERVICES_SECTOR_PATTERN))
        end
      end
      !(subject.match?(WITHDRAWAL_FUNCTION_PATTERN) && subject.match?(DRAFT_SOURCE_PATTERN))
    end

    def self.selected_source?(source, question, context_numacs)
      return true if %i[pinned viewed selected explicit].any? { |key| [true, 1, 'true', '1'].include?(field(source, key)) }

      numac = field(source, :numac).to_s
      !numac.empty? && (context_numacs.map(&:to_s).include?(numac) ||
        question.match?(/(?<![[:alnum:]])#{Regexp.escape(numac)}(?![[:alnum:]])/iu))
    end

    def self.explicit_case_reference?(source, question)
      case_number = field(source, :case_number).to_s
      !case_number.empty? && question.match?(/(?<![[:alnum:]_:])#{Regexp.escape(case_number)}(?![[:alnum:]_:]|\.[[:alnum:]])/iu)
    end

    def self.field(source, key)
      source[key] || source[key.to_s]
    end

    def self.normalized(question)
      question.to_s.gsub(/[[:space:]]+/, ' ')
    end
    private_class_method :field, :selected_source?, :explicit_case_reference?, :normalized
  end
end
