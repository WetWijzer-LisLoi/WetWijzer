# frozen_string_literal: true

require 'uri'
require_relative 'commercial_website_gdpr_sources'

module LegalChatbot
  # Provides verified legal facts by querying the articles table directly,
  # using NUMAC + article title patterns to find the specific law provisions
  # that contain authoritative numbers, rules, and structural facts. A small,
  # explicit exception exists for EU legislation that is not present in the
  # Belgian articles corpus: immutable excerpts from the official EUR-Lex text
  # are admitted with their exact article-level EUR-Lex URLs.
  #
  # Belgian topics remain DB-sourced. Official EU excerpts are deliberately
  # narrow and are not a general static fallback.
  #
  # Tax topics (WIB 92, BTW, etc.) have a dual-source strategy:
  # 1. Primary: Justel articles table (content_numac lookup)
  # 2. Fallback: FisconetPlus DB (tax_articles by legislation_id)
  #
  # All DB lookups are cached (1 hour TTL) to avoid per-request overhead.
  class LegalFactProvider
    # The current indexed GGMMI (interprofessional guaranteed average minimum
    # monthly income). This CANNOT be grounded in the corpus: GGMMI
    # indexations are published administratively by the FOD Werkgelegenheid
    # and are never consolidated into the Staatsblad article text (verified
    # 2026-08-03: no article in the corpus contains the indexed amount, and
    # the consolidated CAO nr. 43 Art. 3 text still reads 2.029,88 EUR). This
    # record is therefore the single authority the whole codebase derives
    # from: the injected fact note, the answer directive, the orchestrator's
    # numeral guard and its four localized canonical answers. The locale
    # strings are renderings of the one amount/date, kept pre-rendered so no
    # date-localisation machinery is needed in the answer path.
    #
    # NEXT INDEXATION: update amount/date renderings and push stale_after out.
    # One edit, here; every consumer follows. If the update is forgotten,
    # stale_after makes the guard and the injected note DEGRADE TO SILENCE
    # rather than presenting the old figure as verified current law.
    CURRENT_GGMMI = {
      amount_nl: '2.233,61',   # also the DE rendering
      amount_fr: "2 233,61",
      amount_en: '2,233.61',
      effective_date: Date.new(2026, 7, 1),
      effective_nl: '1 juli 2026',
      effective_fr: '1er juillet 2026',
      effective_de: '1. Juli 2026',
      effective_en: '1 July 2026',
      source_url_nl: 'https://werk.belgie.be/nl/themas/internationaal/detachering/na-te-leven-arbeidsvoorwaarden-geval-van-detachering-naar-1',
      source_url_fr: 'https://emploi.belgique.be/fr/themes/international/detachement/conditions-de-travail-respecter-en-cas-de-detachement-en-1',
      source_url_en: 'https://employment.belgium.be/en/themes/international/posting/working-conditions-be-respected-case-posting-belgium/remuneration',
      # GGMMI indexations follow pivot-index crossings, roughly annually of
      # late; 15 months of validity covers the gap between them with margin.
      stale_after: Date.new(2027, 10, 1)
    }.freeze

    def self.ggmmi_stale?
      Date.current > CURRENT_GGMMI[:stale_after]
    end

    GDPR_PROCESSOR_TOPIC_KEY = 'gdpr_processor'
    GDPR_PROCESSOR_OFFICIAL_SOURCE_ID = 'eu_gdpr_2016_679'
    GDPR_PROCESSOR_REQUIRED_ARTICLES = %w[4 28].freeze
    GDPR_PROCESSOR_QUESTION_PATTERN =
      /(?<![[:alpha:]])(?:verwerker(?:s|sovereenkomst(?:en)?)?|gegevensverwerker(?:s|sovereenkomst(?:en)?)?|subverwerker(?:s)?|data processor(?:s)?|auftragsverarbeiter(?:s)?)(?![[:alpha:]])/iu
    GDPR_PROCESSOR_CONTEXTUAL_QUESTION_PATTERN =
      /(?<![[:alpha:]])(?:processor(?:s)?|sous-traitant(?:s)?)(?![[:alpha:]])/iu
    GDPR_DATA_PROTECTION_CONTEXT_PATTERN =
      /(?<![[:alpha:]])(?:avg|gdpr|rgpd|dsgvo|privacy|persoonsgegevens|personal (?:data|information)|donn[eé]es? (?:à caractère )?personnelles?|personenbezogen(?:e|en) daten|datenschutz|controller|responsable du traitement|verwerkingsverantwoordelijke)(?![[:alpha:]])/iu
    GDPR_RETENTION_TOPIC_KEY = 'gdpr_retention'
    GDPR_RETENTION_REQUIRED_ARTICLES = %w[5 6 13].freeze
    GDPR_RETENTION_QUESTION_PATTERN =
      /(?<![[:alpha:]])(?:bewaar[[:alpha:]]*|bewaren|bewaard|bewaring|bijhouden|opslagtermijn|opslagbeperking|retain[[:alpha:]]*|retention|keep|kept|keeping|stor(?:e|ed|ing|age)|conserv[[:alpha:]]*|gard[[:alpha:]]*|aufbewahr[[:alpha:]]*|(?:ge)?speicher[[:alpha:]]*)(?![[:alpha:]])/iu
    GDPR_RECRUITMENT_DATA_PATTERN =
      /(?<![[:alpha:]])(?:sollicitatie(?:gegevens|[- ]?cv(?:s|['’]s)?)|sollicitant(?:en)?|kandida(?:at|ten)|applicants?|candidats?|candidatures?|bewerber[[:alpha:]]*|bewerbung[[:alpha:]]*|curriculum vitae|r[eé]sum[eé]s?)(?![[:alpha:]])/iu
    GDPR_CV_PATTERN = /(?<![[:alpha:]])cv(?:s|['’]s)?(?![[:alpha:]])/iu
    GDPR_EMPLOYER_CONTEXT_PATTERN =
      /(?<![[:alpha:]])(?:bedrijf|bedrijven|onderneming|werkgever|recruiter|recruitment|company|companies|employer|entreprise|employeur|recruteur|recrutement|unternehmen|arbeitgeber)(?![[:alpha:]])/iu
    GDPR_CORPORATE_CV_PATTERN =
      /(?<![[:alpha:]])(?:commanditaire|co[oö]peratieve|vennootschap|soci[eé]t[eé]|gesellschaft)(?![[:alpha:]])/iu
    GDPR_SPECIAL_SECURITY_CONTEXT_PATTERN =
      /(?<![[:alpha:]])(?:politie[[:alpha:]]*|police|polizei[[:alpha:]]*|inlichting[[:alpha:]]*|intelligence (?:services?|agenc(?:y|ies)|records?|data|gathering)|(?:national|military) intelligence|staatsveiligheid|state security|national security|nationale veiligheid|s[eé]curit[eé] nationale|nationale sicherheit|s[uû]ret[eé] de l['’][eé]tat|services? de renseignement[[:alpha:]]*|nachrichtendienst[[:alpha:]]*|strafrechtelijke vervolging|law enforcement|strafverfolgung)(?![[:alpha:]])/iu
    GDPR_SECURITY_PROCESSING_PURPOSE_PATTERN =
      /(?<![[:alpha:]])(?:strafrechtelijk(?:e)? (?:vervolging|onderzoek[[:alpha:]]*)|onderzoek naar strafbare feiten|criminal (?:investigation[[:alpha:]]*|prosecution)|for law enforcement|intelligence gathering|enqu[eê]tes? (?:criminelles?|p[eé]nales?)|poursuites? p[eé]nales?|strafverfolgung|strafrechtlich[[:alpha:]]* ermittlung[[:alpha:]]*|nachrichtendienstlich[[:alpha:]]* (?:verarbeitung|ermittlung[[:alpha:]]*))(?![[:alpha:]])/iu

    GDPR_RETENTION_SOURCE_LABELS = {
      'nl' => 'AVG — opslagbeperking, rechtsgrond en bewaartermijn',
      'fr' => 'RGPD — limitation de conservation, licéité et durée',
      'de' => 'DSGVO — Speicherbegrenzung, Rechtsgrundlage und Speicherdauer',
      'en' => 'GDPR — storage limitation, legal basis and retention period'
    }.freeze
    GDPR_RETENTION_LAW_TITLES = {
      'nl' => 'Algemene verordening gegevensbescherming (EU) 2016/679',
      'fr' => 'Règlement général sur la protection des données (UE) 2016/679',
      'de' => 'Datenschutz-Grundverordnung (EU) 2016/679',
      'en' => 'General Data Protection Regulation (EU) 2016/679'
    }.freeze

    # Sealed extracts, verified against the official EUR-Lex language editions
    # on 2026-10-10. These are the named paragraphs, not complete articles.
    # In particular, there is no invented universal number of months for CVs.
    GDPR_RETENTION_OFFICIAL_TEXTS = {
      'nl' => {
        '5' => <<~TEXT.strip.freeze,
          e) worden bewaard in een vorm die het mogelijk maakt de betrokkenen niet langer te identificeren dan voor de doeleinden waarvoor de persoonsgegevens worden verwerkt noodzakelijk is; persoonsgegevens mogen voor langere perioden worden opgeslagen voor zover de persoonsgegevens louter met het oog op archivering in het algemeen belang, wetenschappelijk of historisch onderzoek of statistische doeleinden worden verwerkt overeenkomstig artikel 89, lid 1, mits de bij deze verordening vereiste passende technische en organisatorische maatregelen worden getroffen om de rechten en vrijheden van de betrokkene te beschermen („opslagbeperking”);
        TEXT
        '6' => <<~TEXT.strip.freeze,
          1. De verwerking is alleen rechtmatig indien en voor zover aan ten minste een van de onderstaande voorwaarden is voldaan:
          a) de betrokkene heeft toestemming gegeven voor de verwerking van zijn persoonsgegevens voor een of meer specifieke doeleinden;
          b) de verwerking is noodzakelijk voor de uitvoering van een overeenkomst waarbij de betrokkene partij is, of om op verzoek van de betrokkene vóór de sluiting van een overeenkomst maatregelen te nemen;
          c) de verwerking is noodzakelijk om te voldoen aan een wettelijke verplichting die op de verwerkingsverantwoordelijke rust;
          d) de verwerking is noodzakelijk om de vitale belangen van de betrokkene of van een andere natuurlijke persoon te beschermen;
          e) de verwerking is noodzakelijk voor de vervulling van een taak van algemeen belang of van een taak in het kader van de uitoefening van het openbaar gezag dat aan de verwerkingsverantwoordelijke is opgedragen;
          f) de verwerking is noodzakelijk voor de behartiging van de gerechtvaardigde belangen van de verwerkingsverantwoordelijke of van een derde, behalve wanneer de belangen of de grondrechten en de fundamentele vrijheden van de betrokkene die tot bescherming van persoonsgegevens nopen, zwaarder wegen dan die belangen, met name wanneer de betrokkene een kind is.
          De eerste alinea, punt f), geldt niet voor de verwerking door overheidsinstanties in het kader van de uitoefening van hun taken.
        TEXT
        '13' => <<~TEXT.strip.freeze
          2. Naast de in lid 1 bedoelde informatie verstrekt de verwerkingsverantwoordelijke de betrokkene bij de verkrijging van de persoonsgegevens de volgende aanvullende informatie om een behoorlijke en transparante verwerking te waarborgen:
          a) de periode gedurende welke de persoonsgegevens zullen worden opgeslagen, of indien dat niet mogelijk is, de criteria ter bepaling van die termijn;
        TEXT
      }.freeze,
      'fr' => {
        '5' => <<~TEXT.strip.freeze,
          e) conservées sous une forme permettant l'identification des personnes concernées pendant une durée n'excédant pas celle nécessaire au regard des finalités pour lesquelles elles sont traitées; les données à caractère personnel peuvent être conservées pour des durées plus longues dans la mesure où elles seront traitées exclusivement à des fins archivistiques dans l'intérêt public, à des fins de recherche scientifique ou historique ou à des fins statistiques conformément à l'article 89, paragraphe 1, pour autant que soient mises en œuvre les mesures techniques et organisationnelles appropriées requises par le présent règlement afin de garantir les droits et libertés de la personne concernée (limitation de la conservation);
        TEXT
        '6' => <<~TEXT.strip.freeze,
          1. Le traitement n'est licite que si, et dans la mesure où, au moins une des conditions suivantes est remplie:
          a) la personne concernée a consenti au traitement de ses données à caractère personnel pour une ou plusieurs finalités spécifiques;
          b) le traitement est nécessaire à l'exécution d'un contrat auquel la personne concernée est partie ou à l'exécution de mesures précontractuelles prises à la demande de celle-ci;
          c) le traitement est nécessaire au respect d'une obligation légale à laquelle le responsable du traitement est soumis;
          d) le traitement est nécessaire à la sauvegarde des intérêts vitaux de la personne concernée ou d'une autre personne physique;
          e) le traitement est nécessaire à l'exécution d'une mission d'intérêt public ou relevant de l'exercice de l'autorité publique dont est investi le responsable du traitement;
          f) le traitement est nécessaire aux fins des intérêts légitimes poursuivis par le responsable du traitement ou par un tiers, à moins que ne prévalent les intérêts ou les libertés et droits fondamentaux de la personne concernée qui exigent une protection des données à caractère personnel, notamment lorsque la personne concernée est un enfant.
          Le point f) du premier alinéa ne s'applique pas au traitement effectué par les autorités publiques dans l'exécution de leurs missions.
        TEXT
        '13' => <<~TEXT.strip.freeze
          2. En plus des informations visées au paragraphe 1, le responsable du traitement fournit à la personne concernée, au moment où les données à caractère personnel sont obtenues, les informations complémentaires suivantes qui sont nécessaires pour garantir un traitement équitable et transparent:
          a) la durée de conservation des données à caractère personnel ou, lorsque ce n'est pas possible, les critères utilisés pour déterminer cette durée;
        TEXT
      }.freeze,
      'de' => {
        '5' => <<~TEXT.strip.freeze,
          e) in einer Form gespeichert werden, die die Identifizierung der betroffenen Personen nur so lange ermöglicht, wie es für die Zwecke, für die sie verarbeitet werden, erforderlich ist; personenbezogene Daten dürfen länger gespeichert werden, soweit die personenbezogenen Daten vorbehaltlich der Durchführung geeigneter technischer und organisatorischer Maßnahmen, die von dieser Verordnung zum Schutz der Rechte und Freiheiten der betroffenen Person gefordert werden, ausschließlich für im öffentlichen Interesse liegende Archivzwecke oder für wissenschaftliche und historische Forschungszwecke oder für statistische Zwecke gemäß Artikel 89 Absatz 1 verarbeitet werden („Speicherbegrenzung“);
        TEXT
        '6' => <<~TEXT.strip.freeze,
          (1) Die Verarbeitung ist nur rechtmäßig, wenn mindestens eine der nachstehenden Bedingungen erfüllt ist:
          a) Die betroffene Person hat ihre Einwilligung zu der Verarbeitung der sie betreffenden personenbezogenen Daten für einen oder mehrere bestimmte Zwecke gegeben;
          b) die Verarbeitung ist für die Erfüllung eines Vertrags, dessen Vertragspartei die betroffene Person ist, oder zur Durchführung vorvertraglicher Maßnahmen erforderlich, die auf Anfrage der betroffenen Person erfolgen;
          c) die Verarbeitung ist zur Erfüllung einer rechtlichen Verpflichtung erforderlich, der der Verantwortliche unterliegt;
          d) die Verarbeitung ist erforderlich, um lebenswichtige Interessen der betroffenen Person oder einer anderen natürlichen Person zu schützen;
          e) die Verarbeitung ist für die Wahrnehmung einer Aufgabe erforderlich, die im öffentlichen Interesse liegt oder in Ausübung öffentlicher Gewalt erfolgt, die dem Verantwortlichen übertragen wurde;
          f) die Verarbeitung ist zur Wahrung der berechtigten Interessen des Verantwortlichen oder eines Dritten erforderlich, sofern nicht die Interessen oder Grundrechte und Grundfreiheiten der betroffenen Person, die den Schutz personenbezogener Daten erfordern, überwiegen, insbesondere dann, wenn es sich bei der betroffenen Person um ein Kind handelt.
          Unterabsatz 1 Buchstabe f gilt nicht für die von Behörden in Erfüllung ihrer Aufgaben vorgenommene Verarbeitung.
        TEXT
        '13' => <<~TEXT.strip.freeze
          (2) Zusätzlich zu den Informationen gemäß Absatz 1 stellt der Verantwortliche der betroffenen Person zum Zeitpunkt der Erhebung dieser Daten folgende weitere Informationen zur Verfügung, die notwendig sind, um eine faire und transparente Verarbeitung zu gewährleisten:
          a) die Dauer, für die die personenbezogenen Daten gespeichert werden oder, falls dies nicht möglich ist, die Kriterien für die Festlegung dieser Dauer;
        TEXT
      }.freeze,
      'en' => {
        '5' => <<~TEXT.strip.freeze,
          (e) kept in a form which permits identification of data subjects for no longer than is necessary for the purposes for which the personal data are processed; personal data may be stored for longer periods insofar as the personal data will be processed solely for archiving purposes in the public interest, scientific or historical research purposes or statistical purposes in accordance with Article 89(1) subject to implementation of the appropriate technical and organisational measures required by this Regulation in order to safeguard the rights and freedoms of the data subject (‘storage limitation’);
        TEXT
        '6' => <<~TEXT.strip.freeze,
          1. Processing shall be lawful only if and to the extent that at least one of the following applies:
          (a) the data subject has given consent to the processing of his or her personal data for one or more specific purposes;
          (b) processing is necessary for the performance of a contract to which the data subject is party or in order to take steps at the request of the data subject prior to entering into a contract;
          (c) processing is necessary for compliance with a legal obligation to which the controller is subject;
          (d) processing is necessary in order to protect the vital interests of the data subject or of another natural person;
          (e) processing is necessary for the performance of a task carried out in the public interest or in the exercise of official authority vested in the controller;
          (f) processing is necessary for the purposes of the legitimate interests pursued by the controller or by a third party, except where such interests are overridden by the interests or fundamental rights and freedoms of the data subject which require protection of personal data, in particular where the data subject is a child.
          Point (f) of the first subparagraph shall not apply to processing carried out by public authorities in the performance of their tasks.
        TEXT
        '13' => <<~TEXT.strip.freeze
          2. In addition to the information referred to in paragraph 1, the controller shall, at the time when personal data are obtained, provide the data subject with the following further information necessary to ensure fair and transparent processing:
          (a) the period for which the personal data will be stored, or if that is not possible, the criteria used to determine that period;
        TEXT
      }.freeze
    }.freeze

    GDPR_RETENTION_ARTICLE_TITLES = {
      'nl' => { '5' => 'Artikel 5, lid 1, punt e', '6' => 'Artikel 6, lid 1', '13' => 'Artikel 13, lid 2, punt a' }.freeze,
      'fr' => { '5' => 'Article 5, paragraphe 1, point e', '6' => 'Article 6, paragraphe 1', '13' => 'Article 13, paragraphe 2, point a' }.freeze,
      'de' => { '5' => 'Artikel 5 Absatz 1 Buchstabe e', '6' => 'Artikel 6 Absatz 1', '13' => 'Artikel 13 Absatz 2 Buchstabe a' }.freeze,
      'en' => { '5' => 'Article 5(1)(e)', '6' => 'Article 6(1)', '13' => 'Article 13(2)(a)' }.freeze
    }.freeze

    GDPR_RETENTION_OFFICIAL_SOURCES = GDPR_RETENTION_OFFICIAL_TEXTS.to_h do |language, articles|
      records = GDPR_RETENTION_REQUIRED_ARTICLES.map do |article_number|
        title = GDPR_RETENTION_ARTICLE_TITLES.fetch(language).fetch(article_number)
        record = {
          source: 'eur_lex', official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID, authority: 'EUR-Lex',
          law_title: GDPR_RETENTION_LAW_TITLES.fetch(language),
          title: "#{GDPR_RETENTION_SOURCE_LABELS.fetch(language)} — #{title}".freeze,
          article_title: title, article_number: article_number, language: language.upcase.freeze,
          url: "https://eur-lex.europa.eu/legal-content/#{language.upcase}/TXT/HTML/?uri=CELEX:32016R0679#art_#{article_number}".freeze,
          aliases: %w[avg gdpr rgpd dsgvo].freeze, article_text: articles.fetch(article_number)
        }
        # EN/DE are original EU language editions, not translated Justel rows.
        record[:language_id] = { 'nl' => 1, 'fr' => 2 }[language] if %w[nl fr].include?(language)
        record.freeze
      end.freeze
      [language, records]
    end.freeze

    GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY = 'gdpr_commercial_website'
    GDPR_COMMERCIAL_WEBSITE_OFFICIAL_EDITION = CommercialWebsiteGdprSources::OFFICIAL_EDITION
    GDPR_COMMERCIAL_WEBSITE_REQUIRED_ARTICLES = CommercialWebsiteGdprSources::REQUIRED_ARTICLES
    GDPR_COMMERCIAL_WEBSITE_SOURCE_LABELS = CommercialWebsiteGdprSources::SOURCE_LABELS
    GDPR_COMMERCIAL_WEBSITE_OFFICIAL_TEXTS = CommercialWebsiteGdprSources::ARTICLE_TEXTS.to_h do |language, articles|
      [language, { '6' => GDPR_RETENTION_OFFICIAL_TEXTS.fetch(language).fetch('6') }.merge(articles).freeze]
    end.freeze
    GDPR_COMMERCIAL_WEBSITE_OFFICIAL_SOURCES = GDPR_COMMERCIAL_WEBSITE_OFFICIAL_TEXTS.to_h do |language, articles|
      records = GDPR_COMMERCIAL_WEBSITE_REQUIRED_ARTICLES.map do |article_number|
        title = CommercialWebsiteGdprSources::ARTICLE_TITLES.fetch(language).fetch(article_number)
        record = {
          source: 'eur_lex', official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID, authority: 'EUR-Lex',
          official_source_topic: GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY,
          official_edition: GDPR_COMMERCIAL_WEBSITE_OFFICIAL_EDITION, verified_on: '2026-10-12',
          law_title: GDPR_RETENTION_LAW_TITLES.fetch(language),
          title: "#{GDPR_COMMERCIAL_WEBSITE_SOURCE_LABELS.fetch(language)} — #{title}".freeze,
          article_title: title, article_number: article_number, language: language.upcase.freeze,
          url: "https://eur-lex.europa.eu/legal-content/#{language.upcase}/TXT/HTML/?uri=CELEX:#{GDPR_COMMERCIAL_WEBSITE_OFFICIAL_EDITION}#art_#{article_number}".freeze,
          aliases: %w[avg gdpr rgpd dsgvo].freeze, article_text: articles.fetch(article_number)
        }
        record[:language_id] = { 'nl' => 1, 'fr' => 2 }[language] if %w[nl fr].include?(language)
        record.freeze
      end.freeze
      [language, records]
    end.freeze

    GDPR_PROCESSOR_SOURCE_LABELS = {
      'nl' => 'AVG — definitie en verplichtingen van de verwerker',
      'fr' => 'RGPD — définition et obligations du sous-traitant',
      'de' => 'DSGVO — Definition und Pflichten des Auftragsverarbeiters',
      'en' => 'GDPR — processor definition and duties'
    }.freeze

    GDPR_PROCESSOR_OFFICIAL_SOURCES = {
      'nl' => [
        {
          source: 'eur_lex',
          official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID,
          authority: 'EUR-Lex',
          law_title: 'Algemene verordening gegevensbescherming (EU) 2016/679',
          title: 'AVG — Artikel 4, lid 8 (definitie verwerker)',
          article_title: 'Artikel 4, lid 8',
          article_number: '4',
          language: 'NL',
          language_id: 1,
          url: 'https://eur-lex.europa.eu/legal-content/NL/TXT/HTML/?uri=CELEX:32016R0679#art_4',
          aliases: %w[avg gdpr gegevensbescherming].freeze,
          article_text: <<~TEXT.strip.freeze
            8) „verwerker”: een natuurlijke persoon of rechtspersoon, een overheidsinstantie, een dienst of een ander orgaan die/dat ten behoeve van de verwerkingsverantwoordelijke persoonsgegevens verwerkt;
          TEXT
        }.freeze,
        {
          source: 'eur_lex',
          official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID,
          authority: 'EUR-Lex',
          law_title: 'Algemene verordening gegevensbescherming (EU) 2016/679',
          title: 'AVG — Artikel 28 (verwerker)',
          article_title: 'Artikel 28',
          article_number: '28',
          language: 'NL',
          language_id: 1,
          url: 'https://eur-lex.europa.eu/legal-content/NL/TXT/HTML/?uri=CELEX:32016R0679#art_28',
          aliases: %w[avg gdpr gegevensbescherming].freeze,
          article_text: <<~TEXT.strip.freeze
            1. Wanneer een verwerking namens een verwerkingsverantwoordelijke wordt verricht, doet de verwerkingsverantwoordelijke uitsluitend een beroep op verwerkers die afdoende garanties met betrekking tot het toepassen van passende technische en organisatorische maatregelen bieden opdat de verwerking aan de vereisten van deze verordening voldoet en de bescherming van de rechten van de betrokkene is gewaarborgd.
            2. De verwerker neemt geen andere verwerker in dienst zonder voorafgaande specifieke of algemene schriftelijke toestemming van de verwerkingsverantwoordelijke. In het geval van algemene schriftelijke toestemming licht de verwerker de verwerkingsverantwoordelijke in over beoogde veranderingen inzake de toevoeging of vervanging van andere verwerkers, waarbij de verwerkingsverantwoordelijke de mogelijkheid wordt geboden tegen deze veranderingen bezwaar te maken.
            3. De verwerking door een verwerker wordt geregeld in een overeenkomst of andere rechtshandeling krachtens het Unierecht of het lidstatelijke recht die de verwerker ten aanzien van de verwerkingsverantwoordelijke bindt, en waarin het onderwerp en de duur van de verwerking, de aard en het doel van de verwerking, het soort persoonsgegevens en de categorieën van betrokkenen, en de rechten en verplichtingen van de verwerkingsverantwoordelijke worden omschreven. Die overeenkomst of andere rechtshandeling bepaalt met name dat de verwerker:
            a) de persoonsgegevens uitsluitend verwerkt op basis van schriftelijke instructies van de verwerkingsverantwoordelijke, onder meer met betrekking tot doorgiften van persoonsgegevens aan een derde land of een internationale organisatie, tenzij een op de verwerker van toepassing zijnde Unierechtelijke of lidstaatrechtelijke bepaling hem tot verwerking verplicht; in dat geval stelt de verwerker de verwerkingsverantwoordelijke, voorafgaand aan de verwerking, in kennis van dat wettelijk voorschrift, tenzij die wetgeving deze kennisgeving om gewichtige redenen van algemeen belang verbiedt;
            b) waarborgt dat de tot het verwerken van de persoonsgegevens gemachtigde personen zich ertoe hebben verbonden vertrouwelijkheid in acht te nemen of door een passende wettelijke verplichting van vertrouwelijkheid zijn gebonden;
            c) alle overeenkomstig artikel 32 vereiste maatregelen neemt;
            d) aan de in de leden 2 en 4 bedoelde voorwaarden voor het in dienst nemen van een andere verwerker voldoet;
            e) rekening houdend met de aard van de verwerking, de verwerkingsverantwoordelijke door middel van passende technische en organisatorische maatregelen, voor zover mogelijk, bijstand verleent bij het vervullen van diens plicht om verzoeken om uitoefening van de in hoofdstuk III vastgestelde rechten van de betrokkene te beantwoorden;
            f) rekening houdend met de aard van de verwerking en de hem ter beschikking staande informatie de verwerkingsverantwoordelijke bijstand verleent bij het doen nakomen van de verplichtingen uit hoofde van de artikelen 32 tot en met 36;
            g) na afloop van de verwerkingsdiensten, naargelang de keuze van de verwerkingsverantwoordelijke, alle persoonsgegevens wist of deze aan hem terugbezorgt, en bestaande kopieën verwijdert, tenzij opslag van de persoonsgegevens Unierechtelijk of lidstaatrechtelijk is verplicht;
            h) de verwerkingsverantwoordelijke alle informatie ter beschikking stelt die nodig is om de nakoming van de in dit artikel neergelegde verplichtingen aan te tonen en audits, waaronder inspecties, door de verwerkingsverantwoordelijke of een door de verwerkingsverantwoordelijke gemachtigde controleur mogelijk maakt en eraan bijdraagt.
            Waar het gaat om de eerste alinea, punt h), stelt de verwerker de verwerkingsverantwoordelijke onmiddellijk in kennis indien naar zijn mening een instructie inbreuk oplevert op deze verordening of op andere Unierechtelijke of lidstaatrechtelijke bepalingen inzake gegevensbescherming.
          TEXT
        }.freeze
      ].freeze
    }.freeze

    GDPR_DIRECT_MARKETING_TOPIC_KEY = 'gdpr_direct_marketing'
    GDPR_DIRECT_MARKETING_REQUIRED_ARTICLES = %w[12 14 15 17 21].freeze
    GDPR_DIRECT_MARKETING_OFFICIAL_EDITION = '02016R0679-20160504'
    GDPR_DIRECT_MARKETING_SOURCE_LABELS = {
      'nl' => 'AVG — herkomst, inzage, wissing en bezwaar tegen direct marketing',
      'fr' => 'RGPD — origine, accès, effacement et opposition à la prospection',
      'de' => 'DSGVO — Herkunft, Auskunft, Löschung und Widerspruch gegen Direktwerbung',
      'en' => 'GDPR — source, access, erasure and direct-marketing objection'
    }.freeze

    # Selected provisions, individually checked in all four official language
    # editions on 2026-10-12; no synthetic Belgian article or canonical answer.
    # Edition: CELEX 02016R0679-20160504 (including its corrigenda).
    # EU Publications Office's original XHTML, same edition as the URLs below:
    # NL: https://publications.europa.eu/resource/cellar/5f2552c2-cc45-11e6-ad7c-01aa75ed71a1.0024.03/DOC_2
    # FR: https://publications.europa.eu/resource/cellar/5f2552c2-cc45-11e6-ad7c-01aa75ed71a1.0021.03/DOC_1
    # DE: https://publications.europa.eu/resource/cellar/5f2552c2-cc45-11e6-ad7c-01aa75ed71a1.0001.02/DOC_3
    # EN: https://publications.europa.eu/resource/cellar/5f2552c2-cc45-11e6-ad7c-01aa75ed71a1.0022.03/DOC_1
    # In particular NL Art.12(3)/(4) uses corrigendum 32016R0679R(03),
    # OJ L 74, 4.3.2021, p.35, not the uncorrected 2016 text.
    # Whitespace is normalized only; the named extracts preserve the legal
    # conditions, exceptions and controller's burden in Art.12(5).
    GDPR_DIRECT_MARKETING_OFFICIAL_TEXTS = {
      'nl' => {
        '12' => <<~TEXT.strip.freeze,
          1. De verwerkingsverantwoordelijke neemt passende maatregelen opdat de betrokkene de in de artikelen 13 en 14 bedoelde informatie en de in de artikelen 15 tot en met 22 en artikel 34 bedoelde communicatie in verband met de verwerking in een beknopte, transparante, begrijpelijke en gemakkelijk toegankelijke vorm en in duidelijke en eenvoudige taal ontvangt, in het bijzonder wanneer de informatie specifiek voor een kind bestemd is. De informatie wordt schriftelijk of met andere middelen, met inbegrip van, indien dit passend is, elektronische middelen, verstrekt. Indien de betrokkene daarom verzoekt, kan de informatie mondeling worden meegedeeld, op voorwaarde dat de identiteit van de betrokkene met andere middelen bewezen is.
          3. De verwerkingsverantwoordelijke verstrekt de betrokkene onverwijld en in ieder geval binnen één maand na ontvangst van het verzoek krachtens de artikelen 15 tot en met 22 informatie over het gevolg dat aan het verzoek is gegeven. Afhankelijk van de complexiteit van de verzoeken en van het aantal verzoeken kan die termijn indien nodig met nog eens twee maanden worden verlengd. De verwerkingsverantwoordelijke stelt de betrokkene binnen één maand na ontvangst van het verzoek in kennis van een dergelijke verlenging, met vermelding van de redenen voor de vertraging. Wanneer de betrokkene zijn verzoek elektronisch indient, wordt de informatie indien mogelijk elektronisch verstrekt, tenzij de betrokkene anderszins verzoekt.
          4. Wanneer de verwerkingsverantwoordelijke geen gevolg geeft aan het verzoek van de betrokkene, deelt hij deze laatste onverwijld en uiterlijk binnen één maand na ontvangst van het verzoek mee waarom het verzoek zonder gevolg is gebleven, en informeert hij hem over de mogelijkheid om een klacht in te dienen bij een toezichthoudende autoriteit en beroep bij de rechter in te stellen.
          5. Het verstrekken van de in de artikelen 13 en 14 bedoelde informatie, en het verstrekken van de communicatie en het treffen van de maatregelen bedoeld in de artikelen 15 tot en met 22 en artikel 34 geschieden kosteloos. Wanneer verzoeken van een betrokkene kennelijk ongegrond of buitensporig zijn, met name vanwege hun repetitieve karakter, mag de verwerkingsverantwoordelijke ofwel: a) een redelijke vergoeding aanrekenen in het licht van de administratieve kosten waarmee het verstrekken van de gevraagde informatie of communicatie en het treffen van de gevraagde maatregelen gepaard gaan; ofwel b) weigeren gevolg te geven aan het verzoek.
          Het is aan de verwerkingsverantwoordelijke om de kennelijk ongegronde of buitensporige aard van het verzoek aan te tonen.
          6. Onverminderd artikel 11 kan de verwerkingsverantwoordelijke, wanneer hij redenen heeft om te twijfelen aan de identiteit van de natuurlijke persoon die het verzoek indient als bedoeld in de artikelen 15 tot en met 21, om aanvullende informatie vragen die nodig is ter bevestiging van de identiteit van de betrokkene.
        TEXT
        '14' => <<~TEXT.strip.freeze,
          1. Wanneer persoonsgegevens niet van de betrokkene zijn verkregen, verstrekt de verwerkingsverantwoordelijke de betrokkene de volgende informatie:
          a) de identiteit en de contactgegevens van de verwerkingsverantwoordelijke en, in voorkomend geval, van de vertegenwoordiger van de verwerkingsverantwoordelijke;
          2. Naast de in lid 1 bedoelde informatie verstrekt de verwerkingsverantwoordelijke de betrokkene de volgende informatie om ten overstaan van de betrokkene een behoorlijke en transparante verwerking te waarborgen:
          f) de bron waar de persoonsgegevens vandaan komen, en in voorkomend geval, of zij afkomstig zijn van openbare bronnen;
          3. De verwerkingsverantwoordelijke verstrekt de in de leden 1 en 2 bedoelde informatie: a) binnen een redelijke termijn, maar uiterlijk binnen één maand na de verkrijging van de persoonsgegevens, afhankelijk van de concrete omstandigheden waarin de persoonsgegevens worden verwerkt; b) indien de persoonsgegevens zullen worden gebruikt voor communicatie met de betrokkene, uiterlijk op het moment van het eerste contact met de betrokkene; of c) indien verstrekking van de gegevens aan een andere ontvanger wordt overwogen, uiterlijk op het tijdstip waarop de persoonsgegevens voor het eerst worden verstrekt.
          5. De leden 1 tot en met 4 zijn niet van toepassing indien en voor zover: a) de betrokkene reeds over de informatie beschikt; b) het verstrekken van die informatie onmogelijk blijkt of onevenredig veel inspanning zou vergen, in het bijzonder bij verwerking met het oog op archivering in het algemeen belang, wetenschappelijk of historisch onderzoek of statistische doeleinden, behoudens de in artikel 89, lid 1, bedoelde voorwaarden en waarborgen, of voor zover de in lid 1 van dit artikel bedoelde verplichting de verwezenlijking van de doeleinden van die verwerking onmogelijk dreigt te maken of ernstig in het gedrang dreigt te brengen. In dergelijke gevallen neemt de verwerkingsverantwoordelijke passende maatregelen om de rechten, de vrijheden en de gerechtvaardigde belangen van de betrokkene te beschermen, waaronder het openbaar maken van de informatie; c) het verkrijgen of verstrekken van de gegevens uitdrukkelijk is voorgeschreven bij Unie- of lidstatelijk recht dat op de verwerkingsverantwoordelijke van toepassing is en dat recht voorziet in passende maatregelen om de gerechtvaardigde belangen van de betrokkene te beschermen; of d) de persoonsgegevens vertrouwelijk moeten blijven uit hoofde van een beroepsgeheim in het kader van Unierecht of lidstatelijk recht, waaronder een wettelijke geheimhoudingsplicht.
        TEXT
        '15' => <<~TEXT.strip.freeze,
          1. De betrokkene heeft het recht om van de verwerkingsverantwoordelijke uitsluitsel te verkrijgen over het al dan niet verwerken van hem betreffende persoonsgegevens en, wanneer dat het geval is, om inzage te verkrijgen van die persoonsgegevens en van de volgende informatie:
          g) wanneer de persoonsgegevens niet bij de betrokkene worden verzameld, alle beschikbare informatie over de bron van die gegevens;
        TEXT
        '17' => <<~TEXT.strip.freeze,
          1. De betrokkene heeft het recht van de verwerkingsverantwoordelijke zonder onredelijke vertraging wissing van hem betreffende persoonsgegevens te verkrijgen en de verwerkingsverantwoordelijke is verplicht persoonsgegevens zonder onredelijke vertraging te wissen wanneer een van de volgende gevallen van toepassing is: a) de persoonsgegevens zijn niet langer nodig voor de doeleinden waarvoor zij zijn verzameld of anderszins verwerkt; b) de betrokkene trekt de toestemming waarop de verwerking overeenkomstig artikel 6, lid 1, punt a), of artikel 9, lid 2, punt a), berust, in, en er is geen andere rechtsgrond voor de verwerking; c) de betrokkene maakt overeenkomstig artikel 21, lid 1, bezwaar tegen de verwerking, en er zijn geen prevalerende dwingende gerechtvaardigde gronden voor de verwerking, of de betrokkene maakt bezwaar tegen de verwerking overeenkomstig artikel 21, lid 2; d) de persoonsgegevens zijn onrechtmatig verwerkt; e) de persoonsgegevens moeten worden gewist om te voldoen aan een in het Unierecht of het lidstatelijke recht neergelegde wettelijke verplichting die op de verwerkingsverantwoordelijke rust; f) de persoonsgegevens zijn verzameld in verband met een aanbod van diensten van de informatiemaatschappij als bedoeld in artikel 8, lid 1.
          3. De leden 1 en 2 zijn niet van toepassing voor zover verwerking nodig is: a) voor het uitoefenen van het recht op vrijheid van meningsuiting en informatie; b) voor het nakomen van een in het Unierecht of het lidstatelijke recht neergelegde wettelijke verwerkingsverplichting die op de verwerkingsverantwoordelijke rust, of voor het vervullen van een taak van algemeen belang of het uitoefenen van het openbaar gezag dat aan de verwerkingsverantwoordelijke is verleend; c) om redenen van algemeen belang op het gebied van volksgezondheid overeenkomstig artikel 9, lid 2, punten h) en i), en artikel 9, lid 3; d) met het oog op archivering in het algemeen belang, wetenschappelijk of historisch onderzoek of statistische doeleinden overeenkomstig artikel 89, lid 1, voor zover het in lid 1 bedoelde recht de verwezenlijking van de doeleinden van die verwerking onmogelijk dreigt te maken of ernstig in het gedrang dreigt te brengen; e) voor de instelling, uitoefening of onderbouwing van een rechtsvordering.
        TEXT
        '21' => <<~TEXT.strip.freeze
          2. Wanneer persoonsgegevens ten behoeve van direct marketing worden verwerkt, heeft de betrokkene te allen tijde het recht bezwaar te maken tegen de verwerking van hem betreffende persoonsgegevens voor dergelijke marketing, met inbegrip van profilering die betrekking heeft op direct marketing.
          3. Wanneer de betrokkene bezwaar maakt tegen verwerking ten behoeve van direct marketing, worden de persoonsgegevens niet meer voor deze doeleinden verwerkt.
          4. Het in de leden 1 en 2 bedoelde recht wordt uiterlijk op het moment van het eerste contact met de betrokkene uitdrukkelijk onder de aandacht van de betrokkene gebracht en duidelijk en gescheiden van enige andere informatie weergegeven.
        TEXT
      }.freeze,
      'fr' => {
        '12' => <<~TEXT.strip.freeze,
          1. Le responsable du traitement prend des mesures appropriées pour fournir toute information visée aux articles 13 et 14 ainsi que pour procéder à toute communication au titre des articles 15 à 22 et de l'article 34 en ce qui concerne le traitement à la personne concernée d'une façon concise, transparente, compréhensible et aisément accessible, en des termes clairs et simples, en particulier pour toute information destinée spécifiquement à un enfant. Les informations sont fournies par écrit ou par d'autres moyens y compris, lorsque c'est approprié, par voie électronique. Lorsque la personne concernée en fait la demande, les informations peuvent être fournies oralement, à condition que l'identité de la personne concernée soit démontrée par d'autres moyens.
          3. Le responsable du traitement fournit à la personne concernée des informations sur les mesures prises à la suite d'une demande formulée en application des articles 15 à 22, dans les meilleurs délais et en tout état de cause dans un délai d'un mois à compter de la réception de la demande. Au besoin, ce délai peut être prolongé de deux mois, compte tenu de la complexité et du nombre de demandes. Le responsable du traitement informe la personne concernée de cette prolongation et des motifs du report dans un délai d'un mois à compter de la réception de la demande. Lorsque la personne concernée présente sa demande sous une forme électronique, les informations sont fournies par voie électronique lorsque cela est possible, à moins que la personne concernée ne demande qu'il en soit autrement.
          4. Si le responsable du traitement ne donne pas suite à la demande formulée par la personne concernée, il informe celle-ci sans tarder et au plus tard dans un délai d'un mois à compter de la réception de la demande des motifs de son inaction et de la possibilité d'introduire une réclamation auprès d'une autorité de contrôle et de former un recours juridictionnel.
          5. Aucun paiement n'est exigé pour fournir les informations au titre des articles 13 et 14 et pour procéder à toute communication et prendre toute mesure au titre des articles 15 à 22 et de l'article 34. Lorsque les demandes d'une personne concernée sont manifestement infondées ou excessives, notamment en raison de leur caractère répétitif, le responsable du traitement peut: a) exiger le paiement de frais raisonnables qui tiennent compte des coûts administratifs supportés pour fournir les informations, procéder aux communications ou prendre les mesures demandées; ou b) refuser de donner suite à ces demandes.
          Il incombe au responsable du traitement de démontrer le caractère manifestement infondé ou excessif de la demande.
          6. Sans préjudice de l'article 11, lorsque le responsable du traitement a des doutes raisonnables quant à l'identité de la personne physique présentant la demande visée aux articles 15 à 21, il peut demander que lui soient fournies des informations supplémentaires nécessaires pour confirmer l'identité de la personne concernée.
        TEXT
        '14' => <<~TEXT.strip.freeze,
          1. Lorsque les données à caractère personnel n'ont pas été collectées auprès de la personne concernée, le responsable du traitement fournit à celle-ci toutes les informations suivantes:
          a) l'identité et les coordonnées du responsable du traitement et, le cas échéant, du représentant du responsable du traitement;
          2. En plus des informations visées au paragraphe 1, le responsable du traitement fournit à la personne concernée les informations suivantes nécessaires pour garantir un traitement équitable et transparent à l'égard de la personne concernée:
          f) la source d'où proviennent les données à caractère personnel et, le cas échéant, une mention indiquant qu'elles sont issues ou non de sources accessibles au public;
          3. Le responsable du traitement fournit les informations visées aux paragraphes 1 et 2: a) dans un délai raisonnable après avoir obtenu les données à caractère personnel, mais ne dépassant pas un mois, eu égard aux circonstances particulières dans lesquelles les données à caractère personnel sont traitées; b) si les données à caractère personnel doivent être utilisées aux fins de la communication avec la personne concernée, au plus tard au moment de la première communication à ladite personne; ou c) s'il est envisagé de communiquer les informations à un autre destinataire, au plus tard lorsque les données à caractère personnel sont communiquées pour la première fois.
          5. Les paragraphes 1 à 4 ne s'appliquent pas lorsque et dans la mesure où: a) la personne concernée dispose déjà de ces informations; b) la fourniture de telles informations se révèle impossible ou exigerait des efforts disproportionnés, en particulier pour le traitement à des fins archivistiques dans l'intérêt public, à des fins de recherche scientifique ou historique ou à des fins statistiques sous réserve des conditions et garanties visées à l'article 89, paragraphe 1, ou dans la mesure où l'obligation visée au paragraphe 1 du présent article est susceptible de rendre impossible ou de compromettre gravement la réalisation des objectifs dudit traitement. En pareils cas, le responsable du traitement prend des mesures appropriées pour protéger les droits et libertés ainsi que les intérêts légitimes de la personne concernée, y compris en rendant les informations publiquement disponibles; c) l'obtention ou la communication des informations sont expressément prévues par le droit de l'Union ou le droit de l'État membre auquel le responsable du traitement est soumis et qui prévoit des mesures appropriées visant à protéger les intérêts légitimes de la personne concernée; ou d) les données à caractère personnel doivent rester confidentielles en vertu d'une obligation de secret professionnel réglementée par le droit de l'Union ou le droit des États membre, y compris une obligation légale de secret professionnel.
        TEXT
        '15' => <<~TEXT.strip.freeze,
          1. La personne concernée a le droit d'obtenir du responsable du traitement la confirmation que des données à caractère personnel la concernant sont ou ne sont pas traitées et, lorsqu'elles le sont, l'accès auxdites données à caractère personnel ainsi que les informations suivantes:
          g) lorsque les données à caractère personnel ne sont pas collectées auprès de la personne concernée, toute information disponible quant à leur source;
        TEXT
        '17' => <<~TEXT.strip.freeze,
          1. La personne concernée a le droit d'obtenir du responsable du traitement l'effacement, dans les meilleurs délais, de données à caractère personnel la concernant et le responsable du traitement a l'obligation d'effacer ces données à caractère personnel dans les meilleurs délais, lorsque l'un des motifs suivants s'applique: a) les données à caractère personnel ne sont plus nécessaires au regard des finalités pour lesquelles elles ont été collectées ou traitées d'une autre manière; b) la personne concernée retire le consentement sur lequel est fondé le traitement, conformément à l'article 6, paragraphe 1, point a), ou à l'article 9, paragraphe 2, point a), et il n'existe pas d'autre fondement juridique au traitement; c) la personne concernée s'oppose au traitement en vertu de l'article 21, paragraphe 1, et il n'existe pas de motif légitime impérieux pour le traitement, ou la personne concernée s'oppose au traitement en vertu de l'article 21, paragraphe 2; d) les données à caractère personnel ont fait l'objet d'un traitement illicite; e) les données à caractère personnel doivent être effacées pour respecter une obligation légale qui est prévue par le droit de l'Union ou par le droit de l'État membre auquel le responsable du traitement est soumis; f) les données à caractère personnel ont été collectées dans le cadre de l'offre de services de la société de l'information visée à l'article 8, paragraphe 1.
          3. Les paragraphes 1 et 2 ne s'appliquent pas dans la mesure où ce traitement est nécessaire: a) à l'exercice du droit à la liberté d'expression et d'information; b) pour respecter une obligation légale qui requiert le traitement prévue par le droit de l'Union ou par le droit de l'État membre auquel le responsable du traitement est soumis, ou pour exécuter une mission d'intérêt public ou relevant de l'exercice de l'autorité publique dont est investi le responsable du traitement; c) pour des motifs d'intérêt public dans le domaine de la santé publique, conformément à l'article 9, paragraphe 2, points h) et i), ainsi qu'à l'article 9, paragraphe 3; d) à des fins archivistiques dans l'intérêt public, à des fins de recherche scientifique ou historique ou à des fins statistiques conformément à l'article 89, paragraphe 1, dans la mesure où le droit visé au paragraphe 1 est susceptible de rendre impossible ou de compromettre gravement la réalisation des objectifs dudit traitement; ou e) à la constatation, à l'exercice ou à la défense de droits en justice.
        TEXT
        '21' => <<~TEXT.strip.freeze
          2. Lorsque les données à caractère personnel sont traitées à des fins de prospection, la personne concernée a le droit de s'opposer à tout moment au traitement des données à caractère personnel la concernant à de telles fins de prospection, y compris au profilage dans la mesure où il est lié à une telle prospection.
          3. Lorsque la personne concernée s'oppose au traitement à des fins de prospection, les données à caractère personnel ne sont plus traitées à ces fins.
          4. Au plus tard au moment de la première communication avec la personne concernée, le droit visé aux paragraphes 1 et 2 est explicitement porté à l'attention de la personne concernée et est présenté clairement et séparément de toute autre information.
        TEXT
      }.freeze,
      'de' => {
        '12' => <<~TEXT.strip.freeze,
          (1) Der Verantwortliche trifft geeignete Maßnahmen, um der betroffenen Person alle Informationen gemäß den Artikeln 13 und 14 und alle Mitteilungen gemäß den Artikeln 15 bis 22 und Artikel 34, die sich auf die Verarbeitung beziehen, in präziser, transparenter, verständlicher und leicht zugänglicher Form in einer klaren und einfachen Sprache zu übermitteln; dies gilt insbesondere für Informationen, die sich speziell an Kinder richten. Die Übermittlung der Informationen erfolgt schriftlich oder in anderer Form, gegebenenfalls auch elektronisch. Falls von der betroffenen Person verlangt, kann die Information mündlich erteilt werden, sofern die Identität der betroffenen Person in anderer Form nachgewiesen wurde.
          (3) Der Verantwortliche stellt der betroffenen Person Informationen über die auf Antrag gemäß den Artikeln 15 bis 22 ergriffenen Maßnahmen unverzüglich, in jedem Fall aber innerhalb eines Monats nach Eingang des Antrags zur Verfügung. Diese Frist kann um weitere zwei Monate verlängert werden, wenn dies unter Berücksichtigung der Komplexität und der Anzahl von Anträgen erforderlich ist. Der Verantwortliche unterrichtet die betroffene Person innerhalb eines Monats nach Eingang des Antrags über eine Fristverlängerung, zusammen mit den Gründen für die Verzögerung. Stellt die betroffene Person den Antrag elektronisch, so ist sie nach Möglichkeit auf elektronischem Weg zu unterrichten, sofern sie nichts anderes angibt.
          (4) Wird der Verantwortliche auf den Antrag der betroffenen Person hin nicht tätig, so unterrichtet er die betroffene Person ohne Verzögerung, spätestens aber innerhalb eines Monats nach Eingang des Antrags über die Gründe hierfür und über die Möglichkeit, bei einer Aufsichtsbehörde Beschwerde einzulegen oder einen gerichtlichen Rechtsbehelf einzulegen.
          (5) Informationen gemäß den Artikeln 13 und 14 sowie alle Mitteilungen und Maßnahmen gemäß den Artikeln 15 bis 22 und Artikel 34 werden unentgeltlich zur Verfügung gestellt. Bei offenkundig unbegründeten oder — insbesondere im Fall von häufiger Wiederholung — exzessiven Anträgen einer betroffenen Person kann der Verantwortliche entweder a) ein angemessenes Entgelt verlangen, bei dem die Verwaltungskosten für die Unterrichtung oder die Mitteilung oder die Durchführung der beantragten Maßnahme berücksichtigt werden, oder b) sich weigern, aufgrund des Antrags tätig zu werden.
          Der Verantwortliche hat den Nachweis für den offenkundig unbegründeten oder exzessiven Charakter des Antrags zu erbringen.
          (6) Hat der Verantwortliche begründete Zweifel an der Identität der natürlichen Person, die den Antrag gemäß den Artikeln 15 bis 21 stellt, so kann er unbeschadet des Artikels 11 zusätzliche Informationen anfordern, die zur Bestätigung der Identität der betroffenen Person erforderlich sind.
        TEXT
        '14' => <<~TEXT.strip.freeze,
          (1) Werden personenbezogene Daten nicht bei der betroffenen Person erhoben, so teilt der Verantwortliche der betroffenen Person Folgendes mit:
          a) den Namen und die Kontaktdaten des Verantwortlichen sowie gegebenenfalls seines Vertreters;
          (2) Zusätzlich zu den Informationen gemäß Absatz 1 stellt der Verantwortliche der betroffenen Person die folgenden Informationen zur Verfügung, die erforderlich sind, um der betroffenen Person gegenüber eine faire und transparente Verarbeitung zu gewährleisten:
          f) aus welcher Quelle die personenbezogenen Daten stammen und gegebenenfalls ob sie aus öffentlich zugänglichen Quellen stammen;
          (3) Der Verantwortliche erteilt die Informationen gemäß den Absätzen 1 und 2 a) unter Berücksichtigung der spezifischen Umstände der Verarbeitung der personenbezogenen Daten innerhalb einer angemessenen Frist nach Erlangung der personenbezogenen Daten, längstens jedoch innerhalb eines Monats, b) falls die personenbezogenen Daten zur Kommunikation mit der betroffenen Person verwendet werden sollen, spätestens zum Zeitpunkt der ersten Mitteilung an sie, oder, c) falls die Offenlegung an einen anderen Empfänger beabsichtigt ist, spätestens zum Zeitpunkt der ersten Offenlegung.
          (5) Die Absätze 1 bis 4 finden keine Anwendung, wenn und soweit a) die betroffene Person bereits über die Informationen verfügt, b) die Erteilung dieser Informationen sich als unmöglich erweist oder einen unverhältnismäßigen Aufwand erfordern würde; dies gilt insbesondere für die Verarbeitung für im öffentlichen Interesse liegende Archivzwecke, für wissenschaftliche oder historische Forschungszwecke oder für statistische Zwecke vorbehaltlich der in Artikel 89 Absatz 1 genannten Bedingungen und Garantien oder soweit die in Absatz 1 des vorliegenden Artikels genannte Pflicht voraussichtlich die Verwirklichung der Ziele dieser Verarbeitung unmöglich macht oder ernsthaft beeinträchtigt In diesen Fällen ergreift der Verantwortliche geeignete Maßnahmen zum Schutz der Rechte und Freiheiten sowie der berechtigten Interessen der betroffenen Person, einschließlich der Bereitstellung dieser Informationen für die Öffentlichkeit, c) die Erlangung oder Offenlegung durch Rechtsvorschriften der Union oder der Mitgliedstaaten, denen der Verantwortliche unterliegt und die geeignete Maßnahmen zum Schutz der berechtigten Interessen der betroffenen Person vorsehen, ausdrücklich geregelt ist oder d) die personenbezogenen Daten gemäß dem Unionsrecht oder dem Recht der Mitgliedstaaten dem Berufsgeheimnis, einschließlich einer satzungsmäßigen Geheimhaltungspflicht, unterliegen und daher vertraulich behandelt werden müssen.
        TEXT
        '15' => <<~TEXT.strip.freeze,
          (1) Die betroffene Person hat das Recht, von dem Verantwortlichen eine Bestätigung darüber zu verlangen, ob sie betreffende personenbezogene Daten verarbeitet werden; ist dies der Fall, so hat sie ein Recht auf Auskunft über diese personenbezogenen Daten und auf folgende Informationen:
          g) wenn die personenbezogenen Daten nicht bei der betroffenen Person erhoben werden, alle verfügbaren Informationen über die Herkunft der Daten;
        TEXT
        '17' => <<~TEXT.strip.freeze,
          (1) Die betroffene Person hat das Recht, von dem Verantwortlichen zu verlangen, dass sie betreffende personenbezogene Daten unverzüglich gelöscht werden, und der Verantwortliche ist verpflichtet, personenbezogene Daten unverzüglich zu löschen, sofern einer der folgenden Gründe zutrifft: a) Die personenbezogenen Daten sind für die Zwecke, für die sie erhoben oder auf sonstige Weise verarbeitet wurden, nicht mehr notwendig. b) Die betroffene Person widerruft ihre Einwilligung, auf die sich die Verarbeitung gemäß Artikel 6 Absatz 1 Buchstabe a oder Artikel 9 Absatz 2 Buchstabe a stützte, und es fehlt an einer anderweitigen Rechtsgrundlage für die Verarbeitung. c) Die betroffene Person legt gemäß Artikel 21 Absatz 1 Widerspruch gegen die Verarbeitung ein und es liegen keine vorrangigen berechtigten Gründe für die Verarbeitung vor, oder die betroffene Person legt gemäß Artikel 21 Absatz 2 Widerspruch gegen die Verarbeitung ein. d) Die personenbezogenen Daten wurden unrechtmäßig verarbeitet. e) Die Löschung der personenbezogenen Daten ist zur Erfüllung einer rechtlichen Verpflichtung nach dem Unionsrecht oder dem Recht der Mitgliedstaaten erforderlich, dem der Verantwortliche unterliegt. f) Die personenbezogenen Daten wurden in Bezug auf angebotene Dienste der Informationsgesellschaft gemäß Artikel 8 Absatz 1 erhoben.
          (3) Die Absätze 1 und 2 gelten nicht, soweit die Verarbeitung erforderlich ist a) zur Ausübung des Rechts auf freie Meinungsäußerung und Information; b) zur Erfüllung einer rechtlichen Verpflichtung, die die Verarbeitung nach dem Recht der Union oder der Mitgliedstaaten, dem der Verantwortliche unterliegt, erfordert, oder zur Wahrnehmung einer Aufgabe, die im öffentlichen Interesse liegt oder in Ausübung öffentlicher Gewalt erfolgt, die dem Verantwortlichen übertragen wurde; c) aus Gründen des öffentlichen Interesses im Bereich der öffentlichen Gesundheit gemäß Artikel 9 Absatz 2 Buchstaben h und i sowie Artikel 9 Absatz 3; d) für im öffentlichen Interesse liegende Archivzwecke, wissenschaftliche oder historische Forschungszwecke oder für statistische Zwecke gemäß Artikel 89 Absatz 1, soweit das in Absatz 1 genannte Recht voraussichtlich die Verwirklichung der Ziele dieser Verarbeitung unmöglich macht oder ernsthaft beeinträchtigt, oder e) zur Geltendmachung, Ausübung oder Verteidigung von Rechtsansprüchen.
        TEXT
        '21' => <<~TEXT.strip.freeze
          (2) Werden personenbezogene Daten verarbeitet, um Direktwerbung zu betreiben, so hat die betroffene Person das Recht, jederzeit Widerspruch gegen die Verarbeitung sie betreffender personenbezogener Daten zum Zwecke derartiger Werbung einzulegen; dies gilt auch für das Profiling, soweit es mit solcher Direktwerbung in Verbindung steht.
          (3) Widerspricht die betroffene Person der Verarbeitung für Zwecke der Direktwerbung, so werden die personenbezogenen Daten nicht mehr für diese Zwecke verarbeitet.
          (4) Die betroffene Person muss spätestens zum Zeitpunkt der ersten Kommunikation mit ihr ausdrücklich auf das in den Absätzen 1 und 2 genannte Recht hingewiesen werden; dieser Hinweis hat in einer verständlichen und von anderen Informationen getrennten Form zu erfolgen.
        TEXT
      }.freeze,
      'en' => {
        '12' => <<~TEXT.strip.freeze,
          1. The controller shall take appropriate measures to provide any information referred to in Articles 13 and 14 and any communication under Articles 15 to 22 and 34 relating to processing to the data subject in a concise, transparent, intelligible and easily accessible form, using clear and plain language, in particular for any information addressed specifically to a child. The information shall be provided in writing, or by other means, including, where appropriate, by electronic means. When requested by the data subject, the information may be provided orally, provided that the identity of the data subject is proven by other means.
          3. The controller shall provide information on action taken on a request under Articles 15 to 22 to the data subject without undue delay and in any event within one month of receipt of the request. That period may be extended by two further months where necessary, taking into account the complexity and number of the requests. The controller shall inform the data subject of any such extension within one month of receipt of the request, together with the reasons for the delay. Where the data subject makes the request by electronic form means, the information shall be provided by electronic means where possible, unless otherwise requested by the data subject.
          4. If the controller does not take action on the request of the data subject, the controller shall inform the data subject without delay and at the latest within one month of receipt of the request of the reasons for not taking action and on the possibility of lodging a complaint with a supervisory authority and seeking a judicial remedy.
          5. Information provided under Articles 13 and 14 and any communication and any actions taken under Articles 15 to 22 and 34 shall be provided free of charge. Where requests from a data subject are manifestly unfounded or excessive, in particular because of their repetitive character, the controller may either: (a) charge a reasonable fee taking into account the administrative costs of providing the information or communication or taking the action requested; or (b) refuse to act on the request.
          The controller shall bear the burden of demonstrating the manifestly unfounded or excessive character of the request.
          6. Without prejudice to Article 11, where the controller has reasonable doubts concerning the identity of the natural person making the request referred to in Articles 15 to 21, the controller may request the provision of additional information necessary to confirm the identity of the data subject.
        TEXT
        '14' => <<~TEXT.strip.freeze,
          1. Where personal data have not been obtained from the data subject, the controller shall provide the data subject with the following information:
          (a) the identity and the contact details of the controller and, where applicable, of the controller's representative;
          2. In addition to the information referred to in paragraph 1, the controller shall provide the data subject with the following information necessary to ensure fair and transparent processing in respect of the data subject:
          (f) from which source the personal data originate, and if applicable, whether it came from publicly accessible sources;
          3. The controller shall provide the information referred to in paragraphs 1 and 2: (a) within a reasonable period after obtaining the personal data, but at the latest within one month, having regard to the specific circumstances in which the personal data are processed; (b) if the personal data are to be used for communication with the data subject, at the latest at the time of the first communication to that data subject; or (c) if a disclosure to another recipient is envisaged, at the latest when the personal data are first disclosed.
          5. Paragraphs 1 to 4 shall not apply where and insofar as: (a) the data subject already has the information; (b) the provision of such information proves impossible or would involve a disproportionate effort, in particular for processing for archiving purposes in the public interest, scientific or historical research purposes or statistical purposes, subject to the conditions and safeguards referred to in Article 89(1) or in so far as the obligation referred to in paragraph 1 of this Article is likely to render impossible or seriously impair the achievement of the objectives of that processing. In such cases the controller shall take appropriate measures to protect the data subject's rights and freedoms and legitimate interests, including making the information publicly available; (c) obtaining or disclosure is expressly laid down by Union or Member State law to which the controller is subject and which provides appropriate measures to protect the data subject's legitimate interests; or (d) where the personal data must remain confidential subject to an obligation of professional secrecy regulated by Union or Member State law, including a statutory obligation of secrecy.
        TEXT
        '15' => <<~TEXT.strip.freeze,
          1. The data subject shall have the right to obtain from the controller confirmation as to whether or not personal data concerning him or her are being processed, and, where that is the case, access to the personal data and the following information:
          (g) where the personal data are not collected from the data subject, any available information as to their source;
        TEXT
        '17' => <<~TEXT.strip.freeze,
          1. The data subject shall have the right to obtain from the controller the erasure of personal data concerning him or her without undue delay and the controller shall have the obligation to erase personal data without undue delay where one of the following grounds applies: (a) the personal data are no longer necessary in relation to the purposes for which they were collected or otherwise processed; (b) the data subject withdraws consent on which the processing is based according to point (a) of Article 6(1), or point (a) of Article 9(2), and where there is no other legal ground for the processing; (c) the data subject objects to the processing pursuant to Article 21(1) and there are no overriding legitimate grounds for the processing, or the data subject objects to the processing pursuant to Article 21(2); (d) the personal data have been unlawfully processed; (e) the personal data have to be erased for compliance with a legal obligation in Union or Member State law to which the controller is subject; (f) the personal data have been collected in relation to the offer of information society services referred to in Article 8(1).
          3. Paragraphs 1 and 2 shall not apply to the extent that processing is necessary: (a) for exercising the right of freedom of expression and information; (b) for compliance with a legal obligation which requires processing by Union or Member State law to which the controller is subject or for the performance of a task carried out in the public interest or in the exercise of official authority vested in the controller; (c) for reasons of public interest in the area of public health in accordance with points (h) and (i) of Article 9(2) as well as Article 9(3); (d) for archiving purposes in the public interest, scientific or historical research purposes or statistical purposes in accordance with Article 89(1) in so far as the right referred to in paragraph 1 is likely to render impossible or seriously impair the achievement of the objectives of that processing; or (e) for the establishment, exercise or defence of legal claims.
        TEXT
        '21' => <<~TEXT.strip.freeze
          2. Where personal data are processed for direct marketing purposes, the data subject shall have the right to object at any time to processing of personal data concerning him or her for such marketing, which includes profiling to the extent that it is related to such direct marketing.
          3. Where the data subject objects to processing for direct marketing purposes, the personal data shall no longer be processed for such purposes.
          4. At the latest at the time of the first communication with the data subject, the right referred to in paragraphs 1 and 2 shall be explicitly brought to the attention of the data subject and shall be presented clearly and separately from any other information.
        TEXT
      }.freeze
    }.freeze

    GDPR_DIRECT_MARKETING_ARTICLE_TITLES = {
      'nl' => { '12' => 'Artikel 12, leden 1 en 3–6', '14' => 'Artikel 14, lid 1, punt a, lid 2, punt f, en leden 3 en 5', '15' => 'Artikel 15, lid 1, punt g', '17' => 'Artikel 17, leden 1 en 3', '21' => 'Artikel 21, leden 2–4' }.freeze,
      'fr' => { '12' => 'Article 12, paragraphes 1 et 3–6', '14' => 'Article 14, paragraphe 1, point a, paragraphe 2, point f, et paragraphes 3 et 5', '15' => 'Article 15, paragraphe 1, point g', '17' => 'Article 17, paragraphes 1 et 3', '21' => 'Article 21, paragraphes 2–4' }.freeze,
      'de' => { '12' => 'Artikel 12 Absätze 1 und 3–6', '14' => 'Artikel 14 Absatz 1 Buchstabe a, Absatz 2 Buchstabe f und Absätze 3 und 5', '15' => 'Artikel 15 Absatz 1 Buchstabe g', '17' => 'Artikel 17 Absätze 1 und 3', '21' => 'Artikel 21 Absätze 2–4' }.freeze,
      'en' => { '12' => 'Article 12(1) and (3)–(6)', '14' => 'Article 14(1)(a), (2)(f), (3) and (5)', '15' => 'Article 15(1)(g)', '17' => 'Article 17(1) and (3)', '21' => 'Article 21(2)–(4)' }.freeze
    }.freeze

    GDPR_DIRECT_MARKETING_OFFICIAL_SOURCES = GDPR_DIRECT_MARKETING_OFFICIAL_TEXTS.to_h do |language, articles|
      records = GDPR_DIRECT_MARKETING_REQUIRED_ARTICLES.map do |article_number|
        title = GDPR_DIRECT_MARKETING_ARTICLE_TITLES.fetch(language).fetch(article_number)
        record = {
          source: 'eur_lex', official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID, authority: 'EUR-Lex',
          official_edition: GDPR_DIRECT_MARKETING_OFFICIAL_EDITION, verified_on: '2026-10-12',
          law_title: GDPR_RETENTION_LAW_TITLES.fetch(language),
          title: "#{GDPR_DIRECT_MARKETING_SOURCE_LABELS.fetch(language)} — #{title}".freeze,
          article_title: title, article_number: article_number, language: language.upcase.freeze,
          url: "https://eur-lex.europa.eu/legal-content/#{language.upcase}/TXT/HTML/?uri=CELEX:#{GDPR_DIRECT_MARKETING_OFFICIAL_EDITION}#art_#{article_number}".freeze,
          aliases: %w[avg gdpr rgpd dsgvo].freeze, article_text: articles.fetch(article_number)
        }
        record[:language_id] = { 'nl' => 1, 'fr' => 2 }[language] if %w[nl fr].include?(language)
        record.freeze
      end.freeze
      [language, records]
    end.freeze

    def self.gdpr_processor_question?(question)
      value = question.to_s
      return true if value.match?(GDPR_PROCESSOR_QUESTION_PATTERN)

      value.match?(GDPR_PROCESSOR_CONTEXTUAL_QUESTION_PATTERN) &&
        value.match?(GDPR_DATA_PROTECTION_CONTEXT_PATTERN)
    end

    def self.gdpr_retention_question?(question)
      value = question.to_s
      return false unless value.match?(GDPR_RETENTION_QUESTION_PATTERN)
      return false if value.match?(GDPR_SECURITY_PROCESSING_PURPOSE_PATTERN)
      # A police/intelligence organisation can also be an ordinary employer.
      # Its recruitment CVs are not investigative records simply because of
      # who employs the recruiter; explicit investigative purposes above remain
      # excluded. "Artificial intelligence company" is not a security service.
      return true if value.match?(GDPR_RECRUITMENT_DATA_PATTERN)
      return false if value.match?(GDPR_SPECIAL_SECURITY_CONTEXT_PATTERN)
      return true if value.match?(GDPR_DATA_PROTECTION_CONTEXT_PATTERN)

      value.match?(GDPR_CV_PATTERN) && value.match?(GDPR_EMPLOYER_CONTEXT_PATTERN) &&
        !value.match?(GDPR_CORPORATE_CV_PATTERN)
    end

    def self.required_official_topic_keys(question)
      keys = []
      keys << GDPR_PROCESSOR_TOPIC_KEY if gdpr_processor_question?(question)
      keys << GDPR_RETENTION_TOPIC_KEY if gdpr_retention_question?(question)
      keys << GDPR_DIRECT_MARKETING_TOPIC_KEY if gdpr_direct_marketing_question?(question)
      keys << GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY if gdpr_commercial_website_question?(question)
      keys
    end

    def self.gdpr_direct_marketing_question?(question)
      TelemarketingPrivacyIntent.topic?(question)
    end

    def self.gdpr_commercial_website_question?(question)
      CommercialWebsiteIntent.topic?(question)
    end

    def self.official_source_question?(question)
      required_official_topic_keys(question).any?
    end

    def self.official_sources_for(topic_key, language:)
      registry, required_articles = case topic_key.to_s
                                    when GDPR_PROCESSOR_TOPIC_KEY
                                      [GDPR_PROCESSOR_OFFICIAL_SOURCES, GDPR_PROCESSOR_REQUIRED_ARTICLES]
                                    when GDPR_RETENTION_TOPIC_KEY
                                      [GDPR_RETENTION_OFFICIAL_SOURCES, GDPR_RETENTION_REQUIRED_ARTICLES]
                                    when GDPR_DIRECT_MARKETING_TOPIC_KEY
                                      [GDPR_DIRECT_MARKETING_OFFICIAL_SOURCES, GDPR_DIRECT_MARKETING_REQUIRED_ARTICLES]
                                    when GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY
                                      [GDPR_COMMERCIAL_WEBSITE_OFFICIAL_SOURCES, GDPR_COMMERCIAL_WEBSITE_REQUIRED_ARTICLES]
                                    else
                                      return []
                                    end
      sources = registry.fetch(language.to_s, [])
      return [] unless sources.map { |source| source.fetch(:article_number) }.sort == required_articles.sort
      return [] unless sources.all? { |source| valid_official_source?(source) }

      # Return shallow copies so response assembly cannot mutate the sealed
      # source records. All nested values are frozen scalars/arrays.
      sources.map(&:dup)
    rescue KeyError, URI::InvalidURIError
      []
    end

    def self.required_official_citations_for(topic_key, language:)
      official_sources_for(topic_key, language: language).map do |source|
        [source.fetch(:url), source.fetch(:article_number)]
      end
    rescue KeyError
      []
    end

    def self.valid_official_source?(source)
      uri = URI.parse(source.fetch(:url))
      article_number = source.fetch(:article_number).to_s
      original_edition = uri.query == 'uri=CELEX:32016R0679' && source[:official_edition].nil? &&
                         source[:official_source_topic].nil?
      corrected_marketing_edition =
        source[:official_source_topic].nil? &&
        source[:official_edition] == GDPR_DIRECT_MARKETING_OFFICIAL_EDITION &&
        uri.query == "uri=CELEX:#{GDPR_DIRECT_MARKETING_OFFICIAL_EDITION}" &&
        GDPR_DIRECT_MARKETING_REQUIRED_ARTICLES.include?(article_number)
      corrected_website_edition =
        source[:official_source_topic] == GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY &&
        source[:official_edition] == GDPR_COMMERCIAL_WEBSITE_OFFICIAL_EDITION &&
        uri.query == "uri=CELEX:#{GDPR_COMMERCIAL_WEBSITE_OFFICIAL_EDITION}" &&
        GDPR_COMMERCIAL_WEBSITE_REQUIRED_ARTICLES.include?(article_number) &&
        source[:article_text] == GDPR_COMMERCIAL_WEBSITE_OFFICIAL_TEXTS.fetch(source.fetch(:language).downcase, {})[article_number]

      source.fetch(:source) == 'eur_lex' &&
        source.fetch(:official_source_id) == GDPR_PROCESSOR_OFFICIAL_SOURCE_ID &&
        source.fetch(:authority) == 'EUR-Lex' &&
        uri.scheme == 'https' && uri.host == 'eur-lex.europa.eu' && uri.userinfo.nil? && uri.port == 443 &&
        uri.path == "/legal-content/#{source.fetch(:language)}/TXT/HTML/" &&
        (original_edition || corrected_marketing_edition || corrected_website_edition) && uri.fragment == "art_#{article_number}" &&
        source.fetch(:article_text).to_s.strip.present?
    end
    private_class_method :valid_official_source?

    # Maps topic keys to their authoritative source in the articles table.
    #
    # Each entry specifies:
    #   numac:            The NUMAC of the law containing the fact
    #   article_patterns: Array of substrings to match against article_title
    #   label:            Human-readable label for the injected context block
    #   indexation_note:  (optional) Current/effective fact placed before article content.
    #                     Used for topics where the law text contains base amounts
    #                     that are adjusted via spilindex (e.g. leefloon, kinderbijslag).
    #
    FACT_SOURCES = {
      # ── Employment & Labor ──────────────────────────────────────────────
      'opzegtermijn' => {
        numac: '1978070303',
        article_patterns: ['Art. 37/2'],
        label: 'Opzegtermijnen - Art. 37/2 Arbeidsovereenkomstenwet'
      },
      'vakantiedagen' => {
        numac: '1971062850',
        article_patterns: ['Art. 3'],
        label: 'Vakantiedagen - Art. 3 Jaarlijkse Vakantiewet'
      },
      'arbeidsduur' => {
        numac: '1971031602',
        article_patterns: ['Art. 19', 'Art. 20'],
        label: 'Arbeidsduur - Art. 19-20 Arbeidswet'
      },
      'klein_verlet' => {
        numac: '1963082803',
        article_patterns: ['Art. 2'],
        label: 'Klein Verlet - Art. 2 KB 28 augustus 1963'
      },
      'moederschapsverlof' => {
        numac: '1971031602',
        article_patterns: ['Art. 39'],
        label: 'Moederschapsverlof - Art. 39 Arbeidswet'
      },
      'vaderschapsverlof' => {
        numac: '1978070303',
        article_patterns: ['Art. 30'],
        label: 'Geboorteverlof - Art. 30 Arbeidsovereenkomstenwet'
      },
      'feestdagen' => {
        numac: '1974010407',
        article_patterns: ['Art. 1', 'Art. 2'],
        label: 'Wettelijke Feestdagen - Art. 1-2 Feestdagenwet'
      },
      'ziekte_uitkering' => {
        numac: '1978070303',
        article_patterns: ['Art. 52', 'Art. 53', 'Art. 54', 'Art. 70', 'Art. 71'],
        label: 'Gewaarborgd loon bij ziekte - Art. 52-71 Arbeidsovereenkomstenwet'
      },

      # ── Social Security ─────────────────────────────────────────────────
      'leefloon' => {
        numac: '2002022559',
        article_patterns: ['Art. 14'],
        label: 'Leefloon - Art. 14 Leefloonwet',
        indexation_note: <<~NOTE.strip
          OPGELET: De bedragen in Art. 14 zijn de wettelijke basisbedragen (2002).
          De actuele bedragen worden aangepast via het spilindexmechanisme.
          Geïndexeerde maandbedragen (vanaf 1 maart 2026):
          - Samenwonende: €893,65/maand (€10.723,75/jaar)
          - Alleenstaande: €1.340,47/maand (€16.085,64/jaar)
          - Samenwonende met gezin ten laste: €1.811,57/maand (€21.738,88/jaar)
          Vermeld altijd de geïndexeerde bedragen, niet de basisbedragen uit de wet.
        NOTE
      },
      'werkloosheid' => {
        numac: '1991013192',
        article_patterns: ['Art. 100', 'Art. 101', 'Art. 102', 'Art. 103', 'Art. 108', 'Art. 114', 'Art. 115'],
        label: 'Werkloosheidsuitkering - Art. 100-115 Werkloosheidsbesluit'
      },
      # ── Tax ─────────────────────────────────────────────────────────
      # Tax entries fall back to the FisconetPlus DB by DOCUMENT TYPE, never by
      # legislation_id. The id comment that used to sit here ("WIB 92 = 1,
      # KB/WIB 92 = 2, BTW = 3, W.Reg. = 4, W.Succ. = 5") was stale and the four
      # entries pinned to id 1 silently returned NOTHING: production has no
      # legislation_id 1 or 2 at all, because tax_legislation rows are recreated by
      # the scraper's merge (it purges stale generations orphaned by the
      # fisconet_id-keyed merge), so ids drift while document_type does not.
      # Verified 2026-08-06: BTW=3, W.Reg.=4, W.Succ.=5, WIB 92=6, KB/WIB 92=7,
      # KB 20=8. Do not reintroduce an id pin here.
      'belastingschijven' => {
        numac: '1992041050',
        article_patterns: ['Art. 130', 'Art. 131', 'Art. 134', 'Art. 178'],
        label: 'Personenbelasting tarieven - Art. 130-134 WIB92',
        fisconet_document_type: 'WIB 92'
      },
      'btw' => {
        numac: '1970072012',
        article_patterns: ['Art. 1'],
        label: 'BTW-tarieven - Art. 1 van KB nr. 20',
        fisconet_document_type: 'KB 20'
      },
      'vennootschapsbelasting' => {
        numac: '1992041050',
        article_patterns: ['Art. 215'],
        label: 'Vennootschapsbelasting - Art. 215 WIB92',
        fisconet_document_type: 'WIB 92'
      },
      'roerende_voorheffing' => {
        numac: '1992041050',
        article_patterns: ['Art. 269', 'Art. 171', 'Art. 21'],
        label: 'Roerende voorheffing - Art. 269 WIB92',
        fisconet_document_type: 'WIB 92'
      },
      'pensioensparen' => {
        numac: '1992041050',
        # '1451' is the same article as '145/1': the fisconet PDF path collapses the
        # superscript in "145<sup>1</sup>", so the corpus holds 1451 and 14510
        # alongside the slash-form 145/21..145/47. Both spellings are listed for the
        # same reason FisconetSearch pins both - matching only one silently drops the
        # pensioensparen article. Do NOT "simplify" by stripping slashes globally:
        # 8/1 and 81 are different BTW articles, and W.Reg. has both 212 and 21/2.
        article_patterns: ['Art. 145/1', 'Art. 1451', 'Art. 145'],
        label: 'Pensioensparen - Art. 145/1 WIB92',
        fisconet_document_type: 'WIB 92'
      },
      'registratierechten' => {
        numac: '2013036154',
        article_patterns: ['Art. 2.9.4'],
        label: 'Registratierechten - Art. 2.9.4 Vlaamse Codex Fiscaliteit'
      },
      'erfbelasting' => {
        numac: '2013036154',
        article_patterns: ['Art. 2.7.4'],
        label: 'Erfbelasting - Art. 2.7.4 Vlaamse Codex Fiscaliteit'
      },

      # ── Employment & Labor (additional) ────────────────────────────────
      'ouderschapsverlof' => {
        numac: '2001013224',
        article_patterns: ['Art. 2', 'Art. 3', 'Art. 4', 'Art. 5', 'Art. 6'],
        label: 'Ouderschapsverlof - Art. 2-6 KB Tijdskrediet'
      },
      'loonbescherming' => {
        numac: '1965041207',
        article_patterns: ['Art. 3', 'Art. 4', 'Art. 5', 'Art. 6', 'Art. 9', 'Art. 10'],
        label: 'Loonbescherming - Art. 3-10 Loonbeschermingswet'
      },

      # ── Pension ─────────────────────────────────────────────────────────
      'pensioenleeftijd' => {
        numac: '2024202431',
        article_patterns: ['Art. 2', 'Art. 3', 'Art. 4'],
        label: 'Pensioenleeftijd - Pensioenhervorming 2024'
      },
      'vervroegd_pensioen' => {
        numac: '2024202431',
        article_patterns: ['Art. 4', 'Art. 5', 'Art. 6', 'Art. 7', 'Art. 8'],
        label: 'Vervroegd pensioen - Art. 4-8 Pensioenhervorming 2024'
      },

      # ── Consumer ────────────────────────────────────────────────────────
      'garantie' => {
        numac: '1804032154',
        article_patterns: %w[Art.1649bis Art.1649ter Art.1649quater Art.1649quinquies Art.1649sexies Art.1649septies Art.1649octies],
        label: 'Consumentenkoop en wettelijke garantie - Art. 1649bis-1649octies Oud Burgerlijk Wetboek'
      },
      'herroepingsrecht' => {
        numac: '2013A11134',
        article_patterns: ['Art. VI.47', 'Art. VI.48', 'Art. VI.49', 'Art. VI.50', 'Art. VI.51', 'Art. VI.52', 'Art. VI.53'],
        label: 'Herroepingsrecht - Art. VI.47-53 Wetboek Economisch Recht'
      },

      # ── Criminal ────────────────────────────────────────────────────────
      'voorlopige_hechtenis' => {
        numac: '1990099963',
        article_patterns: ['Art. 21', 'Art. 22', 'Art. 23', 'Art. 24', 'Art. 25'],
        label: 'Voorlopige hechtenis - Art. 21-25 Wet voorlopige hechtenis'
      },
      'alcohol_rijden' => {
        numac: '1968031601',
        article_patterns: ['Art. 34', 'Art. 35'],
        label: 'Alcohol en rijden - Art. 34-35 Wegverkeerswet (WPW)'
      },

      # ── Housing ─────────────────────────────────────────────────────────
      'huur' => {
        numac: '2018015087',
        article_patterns: ['Art. 7', 'Art. 8', 'Art. 9', 'Art. 10', 'Art. 11', 'Art. 12',
                           'Art. 23', 'Art. 24', 'Art. 25', 'Art. 37'],
        label: 'Woninghuur - Vlaams Woninghuurdecreet 2018'
      },

      # ── Civil ───────────────────────────────────────────────────────────
      'verjaring' => {
        numac: '1804032155',
        article_patterns: ['Art. 2219', 'Art. 2244', 'Art. 2262bis', 'Art. 2277'],
        label: 'Verjaring - Oud Burgerlijk Wetboek'
      },

      # ── Immigration ─────────────────────────────────────────────────────
      'naturalisatie' => {
        numac: '1984900065',
        article_patterns: ['Art. 12bis', 'Art. 12', 'Art. 11'],
        label: 'Belgische nationaliteit - Wetboek Belgische Nationaliteit'
      },
      'gezinshereniging' => {
        numac: '1980121550',
        article_patterns: ['Art. 10', 'Art. 10bis', 'Art. 11', 'Art. 12', 'Art. 13'],
        label: 'Gezinshereniging - Art. 10-13 Vreemdelingenwet'
      },

      # ── GDPR ────────────────────────────────────────────────────────────
      GDPR_PROCESSOR_TOPIC_KEY => {
        official_source_key: GDPR_PROCESSOR_TOPIC_KEY,
        labels: GDPR_PROCESSOR_SOURCE_LABELS
      },
      GDPR_RETENTION_TOPIC_KEY => {
        official_source_key: GDPR_RETENTION_TOPIC_KEY,
        labels: GDPR_RETENTION_SOURCE_LABELS
      },
      GDPR_DIRECT_MARKETING_TOPIC_KEY => {
        official_source_key: GDPR_DIRECT_MARKETING_TOPIC_KEY,
        labels: GDPR_DIRECT_MARKETING_SOURCE_LABELS
      },
      GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY => {
        official_source_key: GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY,
        labels: GDPR_COMMERCIAL_WEBSITE_SOURCE_LABELS
      },

      # ── Social Security Contribution ─────────────────────────────────
      'bijzondere_bijdrage' => {
        numac: '1994021117',
        article_patterns: ['Art. 106', 'Art. 107', 'Art. 108', 'Art. 109',
                           'Art. 110', 'Art. 111', 'Art. 112'],
        label: 'Bijzondere bijdrage sociale zekerheid - Art. 106-112 Wet 30 maart 1994'
      },

      # ── Meal Vouchers ────────────────────────────────────────────────
      'maaltijdcheques' => {
        numac: '1969112813',
        article_patterns: ['Art. 19bis'],
        label: 'Maaltijdcheques - Art. 19bis KB 28 november 1969'
      },

      # ── Legal Interest Rate ──────────────────────────────────────────
      'wettelijke_interest' => {
        numac: '2022A32058',
        article_patterns: ['Art. 5.230', 'Art. 5.231', 'Art. 5.232'],
        label: 'Wettelijke interest - Art. 5.230-5.232 Nieuw BW Boek 5'
      },

      # ── Structural/Negative Facts (sourced from the law that changed them) ──

      # Proeftijd: REPEALED by Eenheidsstatuut 2013.
      # Art. 48 AOW still governs uitzendarbeid (3-day exception).
      # The repealed Art. 38-41 AOW text will show "opgeheven".
      'proeftijd' => {
        numac: '1978070303',
        article_patterns: ['Art. 38', 'Art. 39', 'Art. 40', 'Art. 41', 'Art. 48'],
        label: 'Proeftijd (afgeschaft) - Art. 38-48 Arbeidsovereenkomstenwet'
      },

      # Carensdag: REPEALED by Eenheidsstatuut 2013.
      # Art. 52 AOW now provides gewaarborgd loon from day 1.
      'carensdag' => {
        numac: '1978070303',
        article_patterns: ['Art. 52'],
        label: 'Carensdag (afgeschaft) - Art. 52 Arbeidsovereenkomstenwet'
      },

      # Eenheidsstatuut: Art. 62-70 AOW (uniforme opzegtermijnen).
      # The law eliminated the arbeider/bediende distinction.
      'eenheidsstatuut' => {
        numac: '1978070303',
        article_patterns: ['Art. 37/2', 'Art. 37/4', 'Art. 37/6', 'Art. 37/8',
                           'Art. 62', 'Art. 63', 'Art. 64', 'Art. 65'],
        label: 'Eenheidsstatuut - Art. 37-65 Arbeidsovereenkomstenwet'
      },

      # BV kapitaal: WVV Art. 5:3 (geen minimumkapitaal BV),
      # Art. 5:4 (financieel plan), Art. 7:2 (NV minimum EUR 61.500)
      'bv_kapitaal' => {
        numac: '2019A40586',
        article_patterns: ['Art. 5:3', 'Art. 5:4', 'Art. 7:2'],
        label: 'BV kapitaal - Art. 5:3-5:4 en Art. 7:2 WVV'
      },

      # Puntensysteem: Belgium has NO points system. The Wegverkeerswet
      # Art. 38-42 shows the actual penalty system (judicial withdrawal).
      'puntensysteem' => {
        numac: '1968031601',
        article_patterns: ['Art. 38', 'Art. 39', 'Art. 40', 'Art. 41', 'Art. 42'],
        label: 'Rijbewijssysteem (geen punten) - Art. 38-42 Wegverkeerswet (WPW)'
      },

      # Erfrecht reserve: Post-2018 reform. Art. 913-915 BW Boek 4
      # defines the reserve at 1/2 regardless of number of children.
      'erfrecht' => {
        numac: '2022B30600',
        article_patterns: ['Art. 4.54', 'Art. 4.55', 'Art. 4.56', 'Art. 4.57',
                           'Art. 4.58', 'Art. 4.59', 'Art. 4.60'],
        label: 'Erfrecht reserve - Art. 4.54-4.60 Nieuw BW Boek 4'
      },

      # Opdeciemen: multiplication factor for criminal fines.
      # Wet 5 maart 1952. Art. 1 contains the factor.
      'opdeciemen' => {
        numac: '1952030501',
        article_patterns: ['Art. 1', 'Art. 2'],
        label: 'Opdeciemen strafrechtelijke geldboeten - Wet 5 maart 1952'
      },

      # Orgaandonatie: opt-out system. Art. 10-14 of the 1986 law.
      'orgaandonatie' => {
        numac: '1987009088',
        article_patterns: ['Art. 10', 'Art. 11', 'Art. 12', 'Art. 13', 'Art. 14'],
        label: 'Orgaandonatie (opt-out) - Art. 10-14 Wet 13 juni 1986'
      },

      # Meerderjarigheid: 18 years. This provision remains in Art. 488 of the
      # old Civil Code; new Civil Code Art. 1.2 instead governs temporal
      # application of legislation.
      'meerderjarigheid' => {
        numac: '1804032150',
        article_patterns: ['Art. 488'],
        label: 'Meerderjarigheid - Art. 488 Oud Burgerlijk Wetboek'
      },

      # Minimumloon: CAO nr. 43 is the direct interprofessional source. Art. 3
      # stores the indexed base and Art. 5 defines which normal-pay elements
      # count toward the annual average. The live indexed amount is published
      # by FOD WASO; keep its effective date and source URL explicit so a
      # future indexation cannot silently look current.
      'minimumloon' => {
        numac: '1988050250',
        article_patterns: ['Art. 1', 'Art. 3', 'Art. 5'],
        label: 'GGMMI - Art. 1, 3 en 5 CAO nr. 43',
        note_stale_after: CURRENT_GGMMI[:stale_after],
        # Interpolated from CURRENT_GGMMI so the next indexation is a
        # one-record edit; see that constant for why this cannot be
        # corpus-grounded.
        indexation_note: <<~NOTE.strip,
          GEVERIFIEERDE ACTUELE INDEXATIE (FOD Werkgelegenheid):
          Effectieve datum: #{CURRENT_GGMMI[:effective_date].iso8601}.
          Vanaf #{CURRENT_GGMMI[:effective_nl]} bedraagt het interprofessionele GGMMI voor
          werknemers van 18 jaar en ouder €#{CURRENT_GGMMI[:amount_nl]} bruto per maand.
          Dit is een gemiddeld minimummaandinkomen, niet noodzakelijk het
          bedrag van elke afzonderlijke maand. Een toepasselijke sector- of
          ondernemings-cao kan een hoger minimumloon opleggen.
          VERPLICHTE TEMPORALE TOEPASSING: vergelijk de effectieve datum met
          de CURRENT DATE uit de systeeminstructie. Op of na #{CURRENT_GGMMI[:effective_date].iso8601} is
          €#{CURRENT_GGMMI[:amount_nl]} het actuele bedrag en moet dit in de HOOFDREGEL staan.
          Presenteer oudere bedragen uit Art. 3 dan niet als actueel en noem
          de indexatie van #{CURRENT_GGMMI[:effective_nl]} nooit toekomstig.
          Officiële bron: #{CURRENT_GGMMI[:source_url_nl]}
        NOTE
      },

      # Minimumpensioen: KB 23 december 1996, Art. 131bis-131ter
      # of the coordinated pension law for employees.
      'minimumpensioen' => {
        numac: '2024202431',
        article_patterns: ['Art. 9', 'Art. 10', 'Art. 11', 'Art. 12'],
        label: 'Minimumpensioen - Art. 9-12 Pensioenhervorming 2024'
      },

      # ── Immigration (additional) ────────────────────────────────────────

      # Verblijfskaarten: Art. 30-34 Vreemdelingenwet (A, B, F, F+ cards)
      'verblijfskaart' => {
        numac: '1980121550',
        article_patterns: ['Art. 30', 'Art. 31', 'Art. 32', 'Art. 33', 'Art. 34'],
        label: 'Verblijfsvergunningen - Art. 30-34 Vreemdelingenwet'
      },

      # Single permit / gecombineerde vergunning
      'single_permit' => {
        numac: '2018015287',
        # Representative provisions across the operative procedure in
        # Chapter IV (arts. 15-38), without injecting all 24 articles.
        article_patterns: ['Art. 15', 'Art. 17', 'Art. 18', 'Art. 24',
                           'Art. 26', 'Art. 27', 'Art. 29', 'Art. 31',
                           'Art. 33', 'Art. 34', 'Art. 35', 'Art. 36',
                           'Art. 37', 'Art. 38'],
        label: 'Gecombineerde vergunning - kernbepalingen Art. 15-38 Samenwerkingsakkoord 2 februari 2018'
      },

      # Asiel / internationale bescherming: Art. 48/2-57 Vreemdelingenwet
      'asiel' => {
        numac: '1980121550',
        article_patterns: ['Art. 48/2', 'Art. 48/3', 'Art. 48/4', 'Art. 48/5',
                           'Art. 49', 'Art. 50', 'Art. 51', 'Art. 52',
                           'Art. 55', 'Art. 57'],
        label: 'Internationale bescherming - Art. 48-57 Vreemdelingenwet'
      },

      # Inburgering: Brussels GGC Besluit 18 jan 2024, Art. 2-8
      # (uitvoering ordonnantie 20 juli 2023 inburgeringstraject)
      'inburgering' => {
        numac: '2024000670',
        article_patterns: ['Art. 2', 'Art. 3', 'Art. 4', 'Art. 5',
                           'Art. 6', 'Art. 7', 'Art. 8'],
        label: 'Inburgering - Art. 2-8 Besluit inburgeringstraject 2024'
      },

      # ── Environment & Spatial Planning ──────────────────────────────────

      # Omgevingsvergunning: Decreet 25 april 2014
      'omgevingsvergunning' => {
        numac: '2014036510',
        article_patterns: ['Art. 5', 'Art. 6', 'Art. 7', 'Art. 8',
                           'Art. 15', 'Art. 32', 'Art. 52', 'Art. 53'],
        label: 'Omgevingsvergunning - Omgevingsvergunningsdecreet 25 april 2014'
      },

      # EPC: the certificate and transfer/rental duties are governed by the
      # Energiedecreet, not the Vlaamse Codex Fiscaliteit.
      'epc' => {
        numac: '2009035580',
        article_patterns: ['Art. 11.2.1', 'Art. 11.2.2'],
        content_fingerprints: ['energieprestatiecertificaat', 'certificat de performance énergétique'],
        label: 'EPC - Art. 11.2.1-11.2.2 Energiedecreet'
      },

      # Residential asbestos inventories/certificates are governed by the
      # Materialendecreet. The Welzijnswet concerns workplace protection and
      # must not be injected for a property-transfer/asbestattest question.
      'asbest' => {
        numac: '2012035118',
        article_patterns: ['Art. 33/9', 'Art. 33/10', 'Art. 33/11', 'Art. 33/14'],
        content_fingerprints: %w[asbest amiante],
        label: 'Asbestinventarisattest - Art. 33/9-33/14 Materialendecreet'
      },

      # Bodemattest: NUMAC 2006037062 is the Bodemdecreet. The previously used
      # 2007036482 is the unrelated Decreet Volwassenenonderwijs.
      'bodemattest' => {
        numac: '2006037062',
        article_patterns: ['Art. 101', 'Art. 102'],
        content_fingerprints: ['bodemattest', 'attestation du sol'],
        label: 'Bodemattest - Art. 101-102 Bodemdecreet (OVAM)'
      },

      # Geluid: VLAREM II (Decreet milieuhygiëne 1995), geluidsgerelateerde artikelen
      'geluid' => {
        numac: '1995035716',
        article_patterns: ['Art. 5.1.1_', 'Art. 5.1.3'],
        label: 'Geluidsnormen - VLAREM II / Decreet milieuhygiëne'
      },

      # Kapvergunning: VCRO Art. 4.2.1 + Omgevingsvergunningsdecreet
      'kapvergunning' => {
        numac: '2009A35738',
        article_patterns: ['Art. 4.2.1', 'Art. 4.2.2', 'Art. 4.2.3'],
        label: 'Kapvergunning - Art. 4.2.1-4.2.3 VCRO'
      },

      # Zonnepanelen: Energiedecreet provisions on distributed generation.
      # Art.7.1.6 = minimumsteun hernieuwbare energie
      # Art.7.7.3 = eigenaarsverplichtingen installaties
      # Art.4.1.30/1 = prosumententarief overgangsregeling
      'zonnepanelen' => {
        numac: '2009035580',
        article_patterns: ['Art. 7.1.6', 'Art. 7.7.3', 'Art. 4.1.30/1'],
        label: 'Zonnepanelen - Energiedecreet (hernieuwbare energie)'
      }
    }.freeze

    # The calculated notice values below are safe only while the complete
    # statutory schedules still match the version that was audited. Checking
    # just the section headings would keep emitting stale numbers after a
    # legislative amendment. Each pair is [weeks, seniority range] and is
    # verified inside the correct employer/worker section of Art. 37/2.
    NOTICE_PERIOD_TIERS = {
      1 => {
        employer: [
          ['een', 'minder dan drie maanden'],
          ['drie', 'tussen drie maanden en minder dan vier maanden'],
          ['vier', 'tussen vier maanden en minder dan vijf maanden'],
          ['vijf', 'tussen vijf maanden en minder dan zes maanden'],
          ['zes', 'tussen zes maanden en minder dan negen maanden'],
          ['zeven', 'tussen negen maanden en minder dan twaalf maanden'],
          ['acht', 'tussen twaalf maanden en minder dan vijftien maanden'],
          ['negen', 'tussen vijftien maanden en minder dan achttien maanden'],
          ['tien', 'tussen achttien maanden en minder dan eenentwintig maanden'],
          ['elf', 'tussen eenentwintig maanden en minder dan vierentwintig maanden'],
          ['twaalf', 'tussen twee jaar en minder dan drie jaar'],
          ['dertien', 'tussen drie jaar en minder dan vier jaar'],
          ['vijftien', 'tussen vier jaar en minder dan vijf jaar']
        ],
        worker: [
          ['een', 'minder dan drie maanden'],
          ['twee', 'tussen drie maanden en minder dan zes maanden'],
          ['drie', 'tussen zes maanden en minder dan twaalf maanden'],
          ['vier', 'tussen twaalf maanden en minder dan achttien maanden'],
          ['vijf', 'tussen achttien maanden en minder dan vierentwintig maanden'],
          ['zes', 'tussen twee jaar en minder dan vier jaar'],
          ['zeven', 'tussen vier jaar en minder dan vijf jaar'],
          ['negen', 'tussen vijf jaar en minder dan zes jaar'],
          ['tien', 'tussen zes jaar en minder dan zeven jaar'],
          ['twaalf', 'tussen zeven jaar en minder dan acht jaar'],
          ['dertien', 'acht jaar of meer']
        ],
        growth: [
          'vanaf vijf jaar ancienniteit wordt de opzeggingstermijn verder opgebouwd met drie weken per begonnen jaar ancienniteit',
          'vanaf twintig jaar ancienniteit wordt de opzeggingstermijn verder opgebouwd met twee weken per begonnen jaar ancienniteit',
          'vanaf eenentwintig jaar ancienniteit wordt de opzeggingstermijn verder opgebouwd met een week per begonnen jaar ancienniteit'
        ]
      },
      2 => {
        employer: [
          ['une', 'moins de trois mois'],
          ['trois', 'entre trois mois et moins de quatre mois'],
          ['quatre', 'entre quatre mois et moins de cinq mois'],
          ['cinq', 'entre cinq mois et moins de six mois'],
          ['six', 'entre six mois et moins de neuf mois'],
          ['sept', 'entre neuf et moins de douze mois'],
          ['huit', 'entre douze mois et moins de quinze mois'],
          ['neuf', 'entre quinze mois et moins de dix-huit mois'],
          ['dix', 'entre dix-huit mois et moins de vingt-et-un mois'],
          ['onze', 'entre vingt-et-un mois et moins de vingt-quatre mois'],
          ['douze', 'entre deux ans et moins de trois ans'],
          ['treize', 'entre trois ans et moins de quatre ans'],
          ['quinze', 'entre quatre ans et moins de cinq ans']
        ],
        worker: [
          ['une', 'moins de trois mois'],
          ['deux', 'entre trois mois et moins de six mois'],
          ['trois', 'entre six mois et moins de douze mois'],
          ['quatre', 'entre douze mois et moins de dix-huit mois'],
          ['cinq', 'entre dix-huit mois et moins de vingt-quatre mois'],
          ['six', 'entre deux ans et moins de quatre ans'],
          ['sept', 'entre quatre ans et moins de cinq ans'],
          ['neuf', 'entre cinq ans et moins de six ans'],
          ['dix', 'entre six ans et moins de sept ans'],
          ['douze', 'entre sept ans et moins de huit ans'],
          ['treize', 'huit ans anciennete ou plus']
        ],
        growth: [
          "a partir de cinq ans d'anciennete, le delai de preavis augmente ensuite sur la base de trois semaines par annee d'anciennete entamee",
          "a partir de la vingtieme annee d'anciennete, le delai de preavis augmente ensuite de deux semaines par annee d'anciennete entamee",
          "a partir de vingt-et-un ans d'anciennete, le delai de preavis augmente ensuite sur la base d'une semaine par annee d'anciennete entamee"
        ]
      }
    }.freeze

    # Cache TTL for DB lookups (1 hour)
    CACHE_TTL = 1.hour
    # Version segment of the formatted-fact cache key, bumped whenever the
    # formatted block changes shape. r47 (root 2026-10-19 21:40:06): the blocks
    # became complete, and a warm cache must never serve a block cut under the
    # old format after the deploy. The key stays bounded: version, topic and
    # language, never anything derived from the question.
    FACT_CACHE_VERSION = 'r47'

    # FisconetPlus DB path (same as FisconetSearch)
    FISCONET_DB = ENV.fetch('FISCONET_DB', '/mnt/HC_Volume_104299669/embeddings/fisconet.sqlite3')

    def initialize(language: 'nl')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
    end

    # Fetch verified article text for a given topic key.
    # Returns formatted text block or nil if no matching articles found.
    # For tax topics with fisconet_legislation_id, tries Justel first,
    # then falls back to FisconetPlus DB.
    def fetch_facts(topic_key, question: nil)
      source = FACT_SOURCES[topic_key]
      return nil unless source

      base_result = if source[:official_source_key]
                      fetch_from_official_source(source)
                    else
                      cache_key = "legal_fact_provider/#{FACT_CACHE_VERSION}/#{topic_key}/lang_#{@language_id}"
                      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
                        result = fetch_from_db(source)

                        # Fallback to FisconetPlus for tax topics if Justel has no data
                        fisconet_source = source[:fisconet_legislation_id] || source[:fisconet_document_type]
                        result = fetch_from_fisconet(source) if result.nil? && fisconet_source

                        result
                      end
                    end

      return base_result if question.blank?

      case topic_key
      when 'minimumloon'
        directive = minimum_wage_current_answer_directive(question)
        prepend_fact_directive(base_result, directive)
      when 'opzegtermijn'
        calculation = notice_period_calculation(question)
        [base_result, calculation].compact.join("\n")
      else
        base_result
      end
    rescue StandardError => e
      Rails.logger.warn("[FACTPROVIDER] Fact fetch failed: #{e.class}")
      nil
    end

    # Source-shaped records used by the orchestrator, LinkGuard,
    # CitationGuard, QuoteGuard, and source cards. DB-backed facts are already
    # represented by normal retrieval results and therefore return no records
    # here.
    def authoritative_sources_for(topic_key)
      source = FACT_SOURCES[topic_key]
      return [] unless source&.fetch(:official_source_key, nil)

      self.class.official_sources_for(source.fetch(:official_source_key), language: @language)
    rescue StandardError => e
      Rails.logger.warn("[FACTPROVIDER] Official source fetch failed: #{e.class}")
      []
    end

    # Fetch facts for multiple topic keys at once.
    # Returns hash of { topic_key => formatted_text }
    def fetch_facts_bulk(topic_keys)
      results = {}
      topic_keys.each do |key|
        text = fetch_facts(key)
        results[key] = text if text.present?
      end
      results
    end

    # Check which topics have available data in the DB or sealed official
    # source set. Useful for diagnostics and verification.
    def available_topics
      FACT_SOURCES.keys.select { |key| fetch_facts(key).present? }
    end

    private

    def prepend_fact_directive(facts, directive)
      return facts if facts.blank? || directive.blank?

      label, *content = facts.lines.map(&:chomp)
      [label, directive, *content].join("\n")
    end

    # Generic/current questions need a stronger output contract than dated
    # historical questions. Without it, smaller models can acknowledge the
    # current indexation but move the amount into "exceptions", headline an
    # obsolete Art. 3 amount, or turn the verified fact into a fabricated
    # blockquote that QuoteGuard must remove.
    def minimum_wage_current_answer_directive(question)
      normalized = question.to_s.downcase
      explicit_years = normalized.scan(/\b(?:19|20)\d{2}\b/).map(&:to_i)
      historical_wording = normalized.match?(
        /\b(?:historisch|vroeger|destijds|toenmalig|history|historical|previously|anciennement|historique|damals|historisch)\b/i
      )
      return if historical_wording || explicit_years.any? { |year| year != Date.current.year }

      # A stale record must not be presented as the verified current amount:
      # degrade to no directive (the base article facts still flow) rather
      # than instructing the model to headline an outdated figure.
      if self.class.ggmmi_stale?
        Rails.logger.warn('[FACTPROVIDER] CURRENT_GGMMI is past stale_after; minimum-wage directive suppressed')
        return
      end

      # The named obsolete amounts are deliberately literal: they are the
      # figures the consolidated corpus text actually contains, which is
      # exactly why the model must be told not to headline them.
      <<~DIRECTIVE.strip
        VERPLICHTE ANTWOORDVORM VOOR DEZE ACTUELE VRAAG: zet in de eerste
        inhoudelijke zin onder HOOFDREGEL dat het interprofessionele GGMMI
        sinds #{CURRENT_GGMMI[:effective_nl]} €#{CURRENT_GGMMI[:amount_nl]} bruto per maand bedraagt voor werknemers
        van 18 jaar en ouder. Houd datum en bedrag in dezelfde zin. Dit is de
        hoofdregel, geen uitzondering en geen toekomstig bedrag. Formuleer dit
        als gewone uitleg; maak er geen blockquote of verzonnen letterlijk
        citaat van. Presenteer €2.029,88, €1.668,86 en €1.688,03 niet als
        actuele bedragen of actuele leeftijds-/anciënniteitsuitzonderingen.
      DIRECTIVE
    end

    def fetch_from_official_source(source)
      records = authoritative_sources_for(source.fetch(:official_source_key))
      return nil if records.empty?

      label = source.fetch(:labels).fetch(@language, nil)
      return nil if label.blank?

      format_official_article_block(label, records)
    end

    def format_official_article_block(label, records)
      lines = ["[#{label}]"]
      records.each do |record|
        text = record.fetch(:article_text).to_s.strip
        return nil if text.blank?

        lines << "#{record.fetch(:article_title)}: #{text}"
        lines << "LINK: #{record.fetch(:url)}"
      end
      lines.join("\n")
    end

    # Art. 37/2 stores the employer ladder as prose/formulas. Supplying only a
    # truncated article made the model reconstruct that ladder from memory and
    # produced dozens of wrong 5/7/10/15/20/25/30-year figures. Derive the
    # requested bracket deterministically, but only while the live source text
    # still contains the statutory fingerprints this calculation implements.
    def notice_period_calculation(question)
      months = seniority_months(question)
      return nil unless months

      article = Article.where(content_numac: '1978070303', language_id: @language_id)
                       .where("LOWER(REPLACE(article_title, ' ', '')) = 'art.37/2'")
                       .first
      source_text = article&.article_text.to_s
      return nil unless current_notice_period_source?(source_text)

      employer_weeks = employer_notice_weeks(months)
      employee_weeks = employee_notice_weeks(months)
      years = months / 12
      remainder_months = months % 12

      case @language
      when 'fr'
        <<~FACT.strip
          [Application déterministe de l'article 37/2 pour l'ancienneté demandée]
          Ancienneté détectée: #{years} an(s)#{" et #{remainder_months} mois" if remainder_months.positive?}.
          Préavis donné par l'employeur (§ 1): #{employer_weeks} semaines.
          Préavis donné par le travailleur (§ 2): #{employee_weeks} semaines.
          Ne confondez pas ces deux barèmes; si l'auteur du préavis n'est pas indiqué, mentionnez les deux.
        FACT
      when 'de'
        <<~FACT.strip
          [Deterministische Anwendung von Artikel 37/2 auf die angegebene Betriebszugehörigkeit]
          Erkannte Betriebszugehörigkeit: #{years} Jahr(e)#{" und #{remainder_months} Monate" if remainder_months.positive?}.
          Kündigung durch den Arbeitgeber (§ 1): #{employer_weeks} Wochen.
          Kündigung durch den Arbeitnehmer (§ 2): #{employee_weeks} Wochen.
          Diese beiden Tabellen nicht verwechseln; ist die kündigende Partei unklar, beide Werte nennen.
        FACT
      when 'en'
        <<~FACT.strip
          [Deterministic application of Article 37/2 to the stated seniority]
          Detected seniority: #{years} year(s)#{" and #{remainder_months} months" if remainder_months.positive?}.
          Notice by the employer (§ 1): #{employer_weeks} weeks.
          Notice by the employee (§ 2): #{employee_weeks} weeks.
          Do not confuse the two schedules; if the terminating party is unclear, state both.
        FACT
      else
        <<~FACT.strip
          [Deterministische toepassing van Art. 37/2 op de gevraagde anciënniteit]
          Herkende anciënniteit: #{years} jaar#{" en #{remainder_months} maanden" if remainder_months.positive?}.
          Opzegging door de werkgever (§ 1): #{employer_weeks} weken.
          Opzegging door de werknemer (§ 2): #{employee_weeks} weken.
          Verwar deze twee tabellen niet; als niet staat wie opzegt, vermeld beide.
        FACT
      end
    end

    def seniority_months(question)
      q = question.to_s.downcase
      duration_pattern = /(?:(?<years>\d+(?:[,.]\d+)?)\s*(?:jaar|jaren|an|ans|annee|annees|année|années|year|years|jahr|jahre|jahren))(?:\s*(?:,|en|et|and|und)?\s*(?<months>\d+)\s*(?:maand|maanden|mois|month|months|monat|monate|monaten))?|(?<months_only>\d+)\s*(?:maand|maanden|mois|month|months|monat|monate|monaten)/i
      candidates = q.to_enum(:scan, duration_pattern).map do
        match = Regexp.last_match
        {
          years: match[:years]&.tr(',', '.')&.to_f || 0,
          months: (match[:months] || match[:months_only]).to_i,
          begin: match.begin(0),
          end: match.end(0)
        }
      end
      return nil if candidates.empty?

      context_pattern = /\b(?:anci[eë]nniteit|anciennet[eé]|dienstjaren?|in\s+dienst|tewerkgesteld|werkzaam|employed|worked|service|betriebszugeh[oö]rigkeit|besch[aä]ftigt|dienstalter)\b/i
      contexts = q.to_enum(:scan, context_pattern).map do
        match = Regexp.last_match
        (match.begin(0)...match.end(0))
      end

      candidate = if contexts.any?
                    candidates.map do |value|
                      distance = contexts.map do |context|
                        if value[:end] < context.begin
                          context.begin - value[:end]
                        elsif context.end < value[:begin]
                          value[:begin] - context.end
                        else
                          0
                        end
                      end.min
                      [value, distance]
                    end.select { |_value, distance| distance <= 120 }
                       .min_by { |_value, distance| distance }
                       &.first
                  else
                    # A lone age is not seniority. If there is no employment
                    # context, accept only one unambiguous duration and reject
                    # common multilingual age constructions.
                    return nil unless candidates.one?
                    return nil if q.match?(/\b(?:ik\s+ben|j['’]ai|i\s+am|ich\s+bin)\s+\d+(?:[,.]\d+)?\s*(?:jaar|jaren|ans?|ann[eé]es?|years?|jahre?)\b/i)

                    candidates.first
                  end
      return nil unless candidate

      years = candidate[:years]
      months = candidate[:months]
      total = (years * 12).floor + months
      total.between?(0, 80 * 12) ? total : nil
    end

    def current_notice_period_source?(text)
      normalized = text.to_s.unicode_normalize(:nfkd)
                       .gsub(/\p{Mn}/, '')
                       .downcase.tr('’', "'").gsub(/\s+/, ' ')
      employer, worker_and_later = normalized.split(/§\s*2\./, 2)
      worker = worker_and_later&.split(/§\s*3\./, 2)&.first
      return false if employer.blank? || worker.blank?

      schedule = NOTICE_PERIOD_TIERS.fetch(@language_id)
      unit = @language_id == 2 ? 'semaine(?:s)?' : '(?:week|weken)'
      sections_match = schedule[:employer].all? do |weeks, range|
        employer.match?(/#{Regexp.escape(weeks)}\s+#{unit}\b[^;]{0,180}#{Regexp.escape(range)}/)
      end && schedule[:worker].all? do |weeks, range|
        worker.match?(/#{Regexp.escape(weeks)}\s+#{unit}\b[^;]{0,180}#{Regexp.escape(range)}/)
      end

      sections_match && schedule[:growth].all? { |marker| employer.include?(marker) }
    end

    def employer_notice_weeks(months)
      return 1 if months < 3
      return 3 if months < 4
      return 4 if months < 5
      return 5 if months < 6
      return 6 if months < 9
      return 7 if months < 12
      return 8 if months < 15
      return 9 if months < 18
      return 10 if months < 21
      return 11 if months < 24

      years = months / 12
      return 12 if years < 3
      return 13 if years < 4
      return 15 if years < 5
      return 18 + ((years - 5) * 3) if years < 20
      return 62 if years == 20

      62 + (years - 20)
    end

    def employee_notice_weeks(months)
      return 1 if months < 3
      return 2 if months < 6
      return 3 if months < 12
      return 4 if months < 18
      return 5 if months < 24

      years = months / 12
      return 6 if years < 4
      return 7 if years < 5
      return 9 if years < 6
      return 10 if years < 7
      return 12 if years < 8

      13
    end

    def fetch_from_db(source)
      articles = Article.where(content_numac: source[:numac], language_id: @language_id)

      return nil if articles.empty?

      # Match articles by title pattern.
      # IMPORTANT: DB stores titles as "Art.3" (no space after dot) while
      # FACT_SOURCES patterns use "Art. 3" (with space).
      # Article numbers must match at a boundary: a bare prefix test made
      # 'Art. 3' match Art.30-39, Art.3bis, Art.3.1, all DIFFERENT articles
      # that then got injected as "verified" facts.
      matching = articles.select do |article|
        next false if article.article_title.blank?

        title = article.article_title.strip

        source[:article_patterns].any? do |pattern|
          if (m = pattern.match(/\AArt\.?\s*(.+)\z/i))
            # Boundary: the number may not continue with a digit, letter
            # suffix (bis/ter), or subdivision (/2, :3, .1)
            num = Regexp.escape(m[1])
            title.match?(/\AArt(?:ikel)?\.?\s*#{num}(?![\d[:alpha:]])(?![\/:.]\d)/i)
          else
            # Non-article patterns (e.g. 'Bijlage') keep substring matching
            title.include?(pattern)
          end
        end
      end

      # The title matcher above deliberately allows a suffix after the number, so
      # "Art.3 TOEKOMSTIG RECHT" matches a request for Art. 3: a space follows the 3 and
      # the boundary test passes. Injecting that as a verified fact would state a rule that
      # is not in force yet through the channel the prompt says overrides everything.
      matching = matching.reject do |article|
        FutureLaw.row_future?(variant: article.try(:article_variant),
                              title: article.article_title,
                              numac: article.try(:content_numac))
      end

      return nil if matching.empty?

      # A correct NUMAC/article label is not enough: historical imports have
      # stored an unrelated law under a requested source identifier. Never
      # elevate such rows to verified facts unless the retrieved source text
      # contains a topic-specific fingerprint.
      fingerprints = Array(source[:content_fingerprints]).map(&:downcase)
      if fingerprints.any?
        source_text = matching.map { |article| article.article_text.to_s.downcase }.join("\n")
        return nil unless fingerprints.any? { |fingerprint| source_text.include?(fingerprint) }
      end

      # Format the matched articles into a coherent block
      format_article_block(
        source[:label], matching,
        indexation_note: source[:indexation_note],
        note_stale_after: source[:note_stale_after]
      )
    end

    def format_article_block(label, articles, indexation_note: nil, note_stale_after: nil)
      article_lines = []

      articles.each do |article|
        title = article.article_title.to_s.strip
        text = article.article_text.to_s.strip

        next if text.blank?

        # Cut a trailing future-law block off first, so the in-force text is what is
        # emitted and the pending change is only named. Rows that are ENTIRELY future law
        # were already rejected by the caller.
        in_force, future_block = FutureLaw.split(text)
        next if in_force.nil?

        text = in_force
        pending = future_block && FutureLaw.effective_date(future_block)

        # r47 (root 2026-10-19 18:59:40): the in-force text is emitted complete. This
        # channel overrides the retrieved evidence, so a cut here could drop a condition
        # even when the main context is whole; the orchestrator counts the whole emitted
        # verified-data block against the statutory allowance before generation.
        if future_block
          text += @language_id == 2 ? " [modification pas encore en vigueur#{pending ? " (#{pending})" : ''}]"
                                    : " [wijziging nog niet in werking#{pending ? " (vanaf #{pending})" : ''}]"
        end

        article_lines << "#{title}: #{text}"
      end

      return nil if article_lines.empty?

      # Put the current/effective amount before historical statutory base
      # figures. Smaller models overweight the first amount they see and can
      # otherwise headline an obsolete figure even though the verified note
      # explicitly overrides it.
      lines = ["[#{label}]"]
      if indexation_note.present?
        # An expired note must never be injected as a verified CURRENT fact:
        # a forgotten update degrades to the bare statutory text instead of
        # asserting an outdated figure with override authority.
        if note_stale_after && Date.current > note_stale_after
          Rails.logger.warn("[FACTPROVIDER] indexation note for #{label} is past its stale_after date; suppressed")
        else
          lines << indexation_note
        end
      end
      lines.concat(article_lines)

      lines.join("\n")
    end

    # Format a block from FisconetPlus tax_articles rows.
    # rows: Array of [article_number, text_nl, text_fr]
    # Regional scopes are named in the injected fact so the model cannot present a
    # single region's rule as the federal one. Federal and jurisdiction-unstated
    # rows are emitted unchanged.
    FISCONET_REGION_LABELS = {
      'vlaams' => 'Vlaams Gewest',
      'waals' => 'Waals Gewest',
      'brussels' => 'Brussels Hoofdstedelijk Gewest'
    }.freeze

    def format_fisconet_block(label, rows)
      lines = ["[#{label}]"]
      is_french = @language_id == 2

      # The pins list both spellings of a sub-article ('145/1' and '1451') because the
      # corpus stores it both ways, so the same provision can come back twice and be
      # injected as two "verified facts" under different numbers. Skip a repeat only
      # when the slash-stripped number matches AND the text is identical: '8/1' and
      # '81' are different BTW articles and must both survive.
      seen = {}
      rows.each do |article_number, text_nl, text_fr, region_nl, region_fr|
        text = is_french ? (text_fr.presence || text_nl) : (text_nl.presence || text_fr)
        text = text.to_s.strip
        next if text.blank?

        # This channel is declared to OVERRIDE the retrieved sources, so a not-yet-in-force
        # rule injected here is the most authoritative wrong answer the system can give.
        # tax_articles has no variant column, so the marker in the body is the only signal.
        # Splitting here also lands before the dedup key below, so a row is never deduped
        # on words that are not in force.
        in_force, future_block = FutureLaw.split(text)
        next if in_force.nil?

        text = in_force
        pending = future_block && FutureLaw.effective_date(future_block)

        key = [article_number.to_s.downcase.delete('/'), text]
        next if seen[key]

        seen[key] = true

        # Complete (r47); counted with the whole verified-data block before generation.
        scope = FISCONET_REGION_LABELS[(is_french ? region_fr : region_nl).to_s]
        # Name the pending change without handing over its text. The model can say a change
        # is coming and when, and has nothing to quote as though it already applied.
        if future_block
          text += is_french ? " [modification pas encore en vigueur#{pending ? " (#{pending})" : ''}]"
                            : " [wijziging nog niet in werking#{pending ? " (vanaf #{pending})" : ''}]"
        end
        lines << "Art. #{article_number}#{scope ? " (#{scope})" : ''}: #{text}"
      end

      return nil if lines.size <= 1

      lines.join("\n")
    end

    # Fetch from FisconetPlus DB for tax topics.
    # Do the jurisdiction columns exist in this fisconet database?
    #
    # Checked rather than assumed, and memoized per instance. The scraper adds
    # region_nl/region_fr through its self-migrating ALTER list, so a database that
    # predates that migration is a legitimate state. Referencing a missing column
    # would raise, and the rescue in fetch_from_fisconet turns any exception into
    # nil - which is precisely the silent-nothing failure this whole change fixes.
    def fisconet_region_columns?(db)
      return @fisconet_region_columns unless @fisconet_region_columns.nil?

      cols = db.execute('PRAGMA table_info(tax_articles)').map { |row| row[1] }
      @fisconet_region_columns = cols.include?('region_nl') && cols.include?('region_fr')
    rescue StandardError
      @fisconet_region_columns = false
    end

    # Same probe, other table. The 2026-08-08 taxonomy-walk switchover dropped
    # is_in_force from tax_legislation, so naming it raises "no such column"
    # and the rescue below returns nil - the silent-nothing failure this file
    # already warns about, reintroduced through the ORDER BY.
    def fisconet_in_force_column?(db)
      return @fisconet_in_force_column unless @fisconet_in_force_column.nil?

      cols = db.execute('PRAGMA table_info(tax_legislation)').map { |row| row[1] }
      @fisconet_in_force_column = cols.include?('is_in_force')
    rescue StandardError
      @fisconet_in_force_column = false
    end

    # Uses document_type + article_number matching.
    def fetch_from_fisconet(source)
      db = fisconet_db
      return nil unless db

      # Fisconet article_number is just the number (e.g., '130', '145/1')
      # while our patterns are 'Art. 130', 'Art. 145/1'. Extract the number part.
      article_numbers = source[:article_patterns].map do |pattern|
        pattern.sub(/\AArt\.?\s*/, '')
      end

      placeholders = article_numbers.map { '?' }.join(',')

      # Registration/succession duties and parts of WIB 92 are regionalised, so the
      # corpus deliberately carries a region's text where it is the only version
      # published. Ordering by length alone would let a verbose Flemish body outrank
      # the federal article and enter the prompt as the authoritative rule, so
      # demote any regionally-scoped row. Federal and jurisdiction-unstated rows
      # keep their existing relative order.
      region_cols = fisconet_region_columns?(db)
      select_cols = if region_cols
                      'a.article_number, a.text_nl, a.text_fr, a.region_nl, a.region_fr'
                    else
                      'a.article_number, a.text_nl, a.text_fr, NULL, NULL'
                    end
      in_force_rank = fisconet_in_force_column?(db) ? 'COALESCE(l.is_in_force, 1) DESC, ' : ''
      region_rank = if region_cols
                      "CASE WHEN COALESCE(a.region_nl, '') IN ('vlaams', 'waals', 'brussels') " \
                        "OR COALESCE(a.region_fr, '') IN ('vlaams', 'waals', 'brussels') " \
                        'THEN 1 ELSE 0 END, '
                    else
                      ''
                    end

      rows = if source[:fisconet_document_type]
               db.execute(
                 "SELECT #{select_cols} FROM tax_articles a " \
                 'JOIN tax_legislation l ON l.id = a.legislation_id ' \
                 "WHERE LOWER(l.document_type) = ? AND a.article_number IN (#{placeholders}) " \
                 "ORDER BY #{in_force_rank}#{region_rank}" \
                 "LENGTH(COALESCE(a.text_nl, a.text_fr, '')) DESC",
                 [source[:fisconet_document_type].downcase] + article_numbers
               )
             else
               db.execute(
                 "SELECT #{select_cols} FROM tax_articles a " \
                 "WHERE a.legislation_id = ? AND a.article_number IN (#{placeholders}) " \
                 "ORDER BY #{region_rank}LENGTH(COALESCE(a.text_nl, a.text_fr, '')) DESC",
                 [source[:fisconet_legislation_id]] + article_numbers
               )
             end

      return nil if rows.empty?

      format_fisconet_block(source[:label], rows)
    rescue StandardError => e
      Rails.logger.warn("[FACTPROVIDER] Fisconet fallback failed: #{e.class}")
      nil
    end

    # Lazy-initialize connection to FisconetPlus SQLite DB
    def fisconet_db
      @fisconet_db ||= SQLite3::Database.new(FISCONET_DB)
    rescue SQLite3::CantOpenException
      Rails.logger.warn("[FACTPROVIDER] FisconetPlus DB not available at #{FISCONET_DB}")
      nil
    end
  end
end
