# frozen_string_literal: true

require 'uri'
require_relative 'commercial_website_gdpr_sources'
require_relative 'gdpr_breach_sources'
require_relative 'gdpr_controller_sources'
require_relative 'gdpr_processor_sources'

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

    # The leefloon schedules of Art. 14, § 1 as the POD MI circulars index them,
    # oldest first. Each was read in full (page 3 of each circular, 2026-11-19);
    # a new circular is one more entry. The note gives every schedule its period
    # and calls the newest the last CONFIRMED one: a later pivot index can come
    # before any date set here, so it never asserts an amount for a period no
    # schedule covers, and the dated schedules stay for questions about their
    # own periods (Sol 2026-11-20 01:17:34Z).
    LEEFLOON_SCHEDULES = [
      { from: Date.new(2026, 3, 1), circular: '25 februari 2026', coefficient: '1,7758',
        url: 'https://www.mi-is.be/nl/wetgeving/omzendbrief-inzake-de-aanpassing-van-de-bedragen-die-tot-de-federale-wetgeving-met-9',
        amounts: [%w[893,65 10.723,75], %w[1.340,47 16.085,64], %w[1.811,57 21.738,88]] },
      { from: Date.new(2026, 9, 1), circular: '11 augustus 2026', coefficient: '1,8114',
        url: 'https://www.mi-is.be/nl/wetgeving/omzendbrief-inzake-de-aanpassing-van-de-bedragen-die-tot-de-federale-wetgeving-met-11',
        amounts: [%w[911,56 10.938,74], %w[1.367,34 16.408,11], %w[1.847,89 22.174,69]] }
    ].freeze
    LEEFLOON_CHECKED_ON = Date.new(2026, 11, 20)
    LEEFLOON_CATEGORIES = ['Categorie 1, samenwonende', 'Categorie 2, alleenstaande',
                           'Categorie 3, persoon die samenwoont met een gezin ten laste'].freeze
    LEEFLOON_MONTHS = %w[januari februari maart april mei juni juli augustus september oktober november december].freeze

    def self.leefloon_date(date)
      "#{date.day} #{LEEFLOON_MONTHS[date.month - 1]} #{date.year}"
    end

    def self.leefloon_note(schedules = LEEFLOON_SCHEDULES, checked_on: LEEFLOON_CHECKED_ON)
      ordered = schedules.sort_by { |schedule| schedule[:from] }
      blocks = ordered.each_with_index.map do |schedule, index|
        following = ordered[index + 1]
        period = if following
                   "VAN #{leefloon_date(schedule[:from])} TOT EN MET #{leefloon_date(following[:from] - 1)}".upcase
                 else
                   "VANAF #{leefloon_date(schedule[:from])} (LAATST BEVESTIGD SCHEMA)".upcase
                 end
        lines = ["Geïndexeerde bedragen #{period} (omzendbrief van #{schedule[:circular]}, coëfficiënt #{schedule[:coefficient]}):"]
        schedule[:amounts].each_with_index do |(month, year), category|
          lines << "- #{LEEFLOON_CATEGORIES[category]}: €#{month}/maand (€#{year}/jaar)"
        end
        lines << "  Bron: #{schedule[:url]}"
        lines.join("\n")
      end
      newest = ordered.last
      <<~NOTE.strip
        OPGELET: De bedragen in Art. 14 zijn de wettelijke basisbedragen (2002). De omzendbrieven van de POD Maatschappelijke Integratie indexeren ze.
        #{blocks.reverse.join("\n")}
        TOEPASSING: kies het schema van de periode waarover de vraag gaat, met zijn begindatum en omzendbrief. Voor een periode vanaf #{leefloon_date(newest[:from])} zijn dit de laatst bevestigde bedragen (gecontroleerd op #{leefloon_date(checked_on)}): noem ze zo en zeg dat een latere indexering ze kan hebben vervangen. Noem nooit een bedrag dat hier niet staat.
        Categorie 3 (Art. 14, § 1, 3°): het recht wordt geopend zodra er ten minste één minderjarig ongehuwd kind is,
        en het dekt meteen het recht van de eventuele echtgeno(o)t(e) of levenspartner. Ook een alleenstaande ouder die
        samenwoont met een minderjarig ongehuwd kind ten laste valt onder categorie 3.
        Vermeld altijd de geïndexeerde bedragen, niet de basisbedragen uit de wet.
      NOTE
    end

    def self.ggmmi_stale?
      Date.current > CURRENT_GGMMI[:stale_after]
    end

    GDPR_PROCESSOR_TOPIC_KEY = 'gdpr_processor'
    GDPR_PROCESSOR_OFFICIAL_SOURCE_ID = 'eu_gdpr_2016_679'
    GDPR_PROCESSOR_REQUIRED_ARTICLES = %w[4 28].freeze
    GDPR_PROCESSOR_OFFICIAL_EDITION = '02016R0679-20160504'
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

    GDPR_BREACH_TOPIC_KEY = 'gdpr_breach'
    GDPR_BREACH_OFFICIAL_EDITION = GdprBreachSources::OFFICIAL_EDITION
    GDPR_BREACH_REQUIRED_ARTICLES = GdprBreachSources::REQUIRED_ARTICLES
    GDPR_BREACH_SOURCE_LABELS = GdprBreachSources::SOURCE_LABELS
    GDPR_BREACH_OFFICIAL_TEXTS = GdprBreachSources::ARTICLE_TEXTS
    GDPR_BREACH_OFFICIAL_SOURCES = GDPR_BREACH_OFFICIAL_TEXTS.to_h do |language, articles|
      records = GDPR_BREACH_REQUIRED_ARTICLES.map do |article_number|
        title = GdprBreachSources::ARTICLE_TITLES.fetch(language).fetch(article_number)
        record = {
          source: 'eur_lex', official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID, authority: 'EUR-Lex',
          official_source_topic: GDPR_BREACH_TOPIC_KEY,
          official_edition: GDPR_BREACH_OFFICIAL_EDITION, verified_on: GdprBreachSources::VERIFIED_ON,
          law_title: GDPR_RETENTION_LAW_TITLES.fetch(language),
          title: "#{GDPR_BREACH_SOURCE_LABELS.fetch(language)} — #{title}".freeze,
          article_title: title, article_number: article_number, language: language.upcase.freeze,
          url: "https://eur-lex.europa.eu/legal-content/#{language.upcase}/TXT/HTML/?uri=CELEX:#{GDPR_BREACH_OFFICIAL_EDITION}#art_#{article_number}".freeze,
          aliases: %w[avg gdpr rgpd dsgvo].freeze, article_text: articles.fetch(article_number)
        }
        record[:language_id] = { 'nl' => 1, 'fr' => 2 }[language] if %w[nl fr].include?(language)
        record.freeze
      end.freeze
      [language, records]
    end.freeze

    GDPR_CONTROLLER_TOPIC_KEY = 'gdpr_controller'
    GDPR_CONTROLLER_OFFICIAL_EDITION = GdprControllerSources::OFFICIAL_EDITION
    GDPR_CONTROLLER_REQUIRED_ARTICLES = GdprControllerSources::REQUIRED_ARTICLES
    GDPR_CONTROLLER_SOURCE_LABELS = GdprControllerSources::SOURCE_LABELS
    GDPR_CONTROLLER_OFFICIAL_TEXTS = GdprControllerSources::ARTICLE_TEXTS
    GDPR_CONTROLLER_OFFICIAL_SOURCES = GDPR_CONTROLLER_OFFICIAL_TEXTS.to_h do |language, articles|
      records = GDPR_CONTROLLER_REQUIRED_ARTICLES.map do |article_number|
        title = GdprControllerSources::ARTICLE_TITLES.fetch(language).fetch(article_number)
        record = {
          source: 'eur_lex', official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID, authority: 'EUR-Lex',
          official_source_topic: GDPR_CONTROLLER_TOPIC_KEY,
          official_edition: GDPR_CONTROLLER_OFFICIAL_EDITION, verified_on: GdprControllerSources::VERIFIED_ON,
          law_title: GDPR_RETENTION_LAW_TITLES.fetch(language),
          title: "#{GDPR_CONTROLLER_SOURCE_LABELS.fetch(language)} — #{title}".freeze,
          article_title: title, article_number: article_number, language: language.upcase.freeze,
          url: "https://eur-lex.europa.eu/legal-content/#{language.upcase}/TXT/HTML/?uri=CELEX:#{GDPR_CONTROLLER_OFFICIAL_EDITION}#art_#{article_number}".freeze,
          aliases: %w[avg gdpr rgpd dsgvo].freeze, article_text: articles.fetch(article_number),
          point: GdprControllerSources::POINTS[article_number]
        }.compact
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

    # #1582 (2026-11-22): the corrected consolidation 02016R0679-20160504, as the other packs. Its Dutch art. 4,
    # point 8, reads "namens de verwerkingsverantwoordelijke", marked as corrected by corrigendum C2 (PB L 74 of
    # 4 March 2021, p. 35); this pack had "ten behoeve van". Art. 28, paragraphs 1 to 3, reads in the consolidation as
    # here.
    GDPR_PROCESSOR_OFFICIAL_SOURCES = {
      'nl' => [
        {
          source: 'eur_lex',
          official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID,
          authority: 'EUR-Lex',
          law_title: 'Algemene verordening gegevensbescherming (EU) 2016/679',
          title: 'AVG — Artikel 4, punt 8 (definitie verwerker)',
          article_title: 'Artikel 4, punt 8',
          article_number: '4',
          point: '8',
          language: 'NL',
          language_id: 1,
          official_source_topic: GDPR_PROCESSOR_TOPIC_KEY,
          official_edition: GDPR_PROCESSOR_OFFICIAL_EDITION,
          verified_on: '2026-11-22',
          url: 'https://eur-lex.europa.eu/legal-content/NL/TXT/HTML/?uri=CELEX:02016R0679-20160504#art_4',
          aliases: %w[avg gdpr gegevensbescherming].freeze,
          article_text: <<~TEXT.strip.freeze
            8) „verwerker” : een natuurlijke persoon of rechtspersoon, een overheidsinstantie, een dienst of een ander orgaan die/dat namens de verwerkingsverantwoordelijke persoonsgegevens verwerkt;
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
          official_source_topic: GDPR_PROCESSOR_TOPIC_KEY,
          official_edition: GDPR_PROCESSOR_OFFICIAL_EDITION,
          verified_on: '2026-11-22',
          url: 'https://eur-lex.europa.eu/legal-content/NL/TXT/HTML/?uri=CELEX:02016R0679-20160504#art_28',
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
    }.merge(
      # #1582 (Sol 2026-11-22 13:14:02Z): without these, a French, German or English processor question, or a
      # difference question, was refused as lacking its official source. See GdprProcessorSources.
      GdprProcessorSources::ARTICLE_TEXTS.to_h do |language, articles|
        records = GDPR_PROCESSOR_REQUIRED_ARTICLES.map do |article_number|
          record = {
            source: 'eur_lex', official_source_id: GDPR_PROCESSOR_OFFICIAL_SOURCE_ID, authority: 'EUR-Lex',
            law_title: GDPR_RETENTION_LAW_TITLES.fetch(language),
            title: GdprProcessorSources::RECORD_TITLES.fetch(language).fetch(article_number),
            article_title: GdprProcessorSources::ARTICLE_TITLES.fetch(language).fetch(article_number),
            article_number: article_number, language: language.upcase.freeze,
            official_source_topic: GDPR_PROCESSOR_TOPIC_KEY, official_edition: GDPR_PROCESSOR_OFFICIAL_EDITION,
            verified_on: GdprProcessorSources::VERIFIED_ON,
            url: "https://eur-lex.europa.eu/legal-content/#{language.upcase}/TXT/HTML/?uri=CELEX:#{GDPR_PROCESSOR_OFFICIAL_EDITION}#art_#{article_number}".freeze,
            aliases: %w[avg gdpr rgpd dsgvo].freeze, article_text: articles.fetch(article_number),
            point: GdprProcessorSources::POINTS[article_number]
          }.compact
          record[:language_id] = 2 if language == 'fr'
          record.freeze
        end.freeze
        [language, records]
      end
    ).freeze

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

    # Belgian fact topics admitted by a bounded pattern instead of the keyword
    # map. A key here changes no topic descriptor, so the semantic topic
    # vectors (ReferenceSheets#topic_descriptors_digest) stay valid and no
    # deploy has to embed them again.
    TRAINING_CLAUSE_TOPIC_KEY = 'scholingsbeding'
    TRAINING_CLAUSE_PATTERN = /(?<![[:alpha:]])(?:scholingsbeding\p{L}*|opleidingsbeding\p{L}*|clauses?\s+d['’]\s*[ée]colage|training\s+(?:repayment\s+)?clauses?|ausbildungsklausel\p{L}*)(?![[:alpha:]])/i

    # "Loon ziekte eerste maand?" matched no keyword topic (Sol 2026-11-20 07:32:27Z, #1732); a deterministic key
    # adds the guaranteed-pay facts without touching the embedded topic descriptors.
    GUARANTEED_PAY_TOPIC_KEY = 'ziekte_uitkering'

    # Capital gains on financial assets, crypto included (Sol 2026-11-20 05:41:41Z, #2675): a deterministic key, so the
    # embedded topic descriptors are unchanged. The amounts are the FOD Financiën figures for income 2026 (page read in
    # full 2026-11-20); the law holds only the base amounts (art. 96/2) and the indexation rule (art. 178).
    # NEXT INDEXATION: replace the amounts and years and push stale_after out.
    CAPITAL_GAINS_TOPIC_KEY = 'meerwaardebelasting'
    CAPITAL_GAINS_INDEXED = {
      income_year: 2026, assessment_year: 2027,
      exemption: '10.000', carry_forward: '1.000', five_year_total: '15.000',
      source_url: 'https://fin.belgium.be/fr/particuliers/declaration-impot/revenus/taxe-plus-values',
      stale_after: Date.new(2027, 6, 30)
    }.freeze

    def self.capital_gains_indexed_current?
      Date.current <= CAPITAL_GAINS_INDEXED[:stale_after]
    end

    # The rental income of a built property (Sol 2026-11-20 05:41:41Z, #2673): a deterministic key. WIB 92 art. 7, 8, 13
    # and 518 were read in full in Fisconet on 2026-11-20; the coefficients and the return codes come from the two FOD
    # Financiën pages read in full the same day. NEXT YEAR: add the new coefficients and push stale_after out.
    RENTAL_INCOME_TOPIC_KEY = 'huurinkomsten'
    RENTAL_INCOME_FIGURES = {
      index: '2,2446 voor inkomstenjaar 2025 (aanslagjaar 2026) en 2,3000 voor inkomstenjaar 2026 (aanslagjaar 2027)',
      revaluation: '5,63 voor aanslagjaar 2026 en 5,75 voor aanslagjaar 2027',
      example: 'aangegeven niet-geïndexeerd kadastraal inkomen 450 euro; geïndexeerd 450 x 2,2446 = 1.010 euro; ' \
               'belastbaar 1.010 x 1,4 = 1.414 euro (inkomstenjaar 2025)',
      source_urls: %w[https://fin.belgium.be/nl/particulieren/woning/huren-verhuren/huurinkomsten/verhuur-particulieren
                      https://fin.belgium.be/nl/particulieren/woning/huren-verhuren/huurinkomsten/professioneel],
      stale_after: Date.new(2027, 6, 30)
    }.freeze

    def self.rental_income_figures_current?
      Date.current <= RENTAL_INCOME_FIGURES[:stale_after]
    end

    # Contesting a pension decision (Sol 2026-11-20 00:21:18Z, #1934): a deterministic key.
    PENSION_APPEAL_TOPIC_KEY = 'pensioen_beroep'
    # The Raad voor Vergunningsbetwistingen (Sol 2026-11-20 10:13:42Z, #2065): a deterministic key.
    PERMIT_COUNCIL_TOPIC_KEY = 'raad_vergunningsbetwistingen'
    # Recidivism under the new Criminal Code (Sol 2026-11-20 01:05:24Z, #1988): a deterministic key.
    RECIDIVISM_TOPIC_KEY = 'herhaling_strafrecht'
    # Receiving a state secret (Sol 2026-11-20 13:46:27Z): a deterministic key.
    STATE_SECRET_TOPIC_KEY = 'staatsgeheim_ontvangen'
    # Witnesses (Sol 2026-11-20 01:05:24Z, catalogue 1671 and 2876): a deterministic key.
    WITNESS_TOPIC_KEY = 'getuigen'

    # The maximumfactuur (MAF) per calendar year (Sol 2026-11-20 02:26:50Z: #131, #293, #821, #2183 gave the statutory
    # bases of 450 and 100 euro as current). The GVU-wet (1994071451) art. 37octies, 37undecies, 37duodecies and
    # 37quaterdecies hold base amounts that are indexed yearly; the amounts per year come from the RIZIV table
    # maximumfactuur-inkomensschijven-plafonds.docx (read in full on 2026-11-20; it states no publication date).
    # NEXT YEAR: add the new year's row from the RIZIV table and move MAF_CHECKED_ON.
    MAF_TOPIC_KEY = 'maximumfactuur'
    MAF_SOURCE_URL = 'https://www.riziv.fgov.be/SiteCollectionDocuments/maximumfactuur-inkomensschijven-plafonds.docx'
    MAF_CHECKED_ON = Date.new(2026, 11, 20)
    MAF_SCHEDULES = {
      2026 => { bands: [['tot 13.402,43', '270,60'], ['13.402,44 tot 23.977,39', '548,55'], ['23.977,40 tot 36.860,74', '792,35'],
                        ['36.860,75 tot 49.744,15', '1.219,00'], ['49.744,16 tot 62.090,73', '1.706,60'], ['vanaf 62.090,74', '2.194,20']],
                social: '548,55', child: '792,35', chronic_reduction: '121,90', chronic_shares: { 2025 => '527,27', 2024 => '516,92' } },
      2025 => { bands: [['tot 13.079,37', '260,10'], ['13.079,38 tot 23.399,42', '527,27'], ['23.399,43 tot 35.972,23', '761,61'],
                        ['35.972,24 tot 48.545,09', '1.171,70'], ['48.545,10 tot 60.594,06', '1.640,38'], ['vanaf 60.594,07', '2.109,06']],
                social: '527,27', child: '761,61', chronic_reduction: '117,17', chronic_shares: { 2024 => '516,92', 2023 => '506,79' } },
      2024 => { bands: [['tot 12.681,18', '254,99'], ['12.681,19 tot 22.687,05', '516,92'], ['22.687,06 tot 34.877,09', '746,66'],
                        ['34.877,10 tot 47.067,18', '1.148,70'], ['47.067,19 tot 58.749,33', '1.608,18'], ['vanaf 58.749,34', '2.067,66']],
                social: '516,92', child: '746,66', chronic_reduction: '114,87', chronic_shares: nil }
    }.freeze
    # Health-care MAF only: the Flemish school "maximumfactuur" is another regime (catalogue 880).
    MAF_PATTERN = /\A(?!.*(?<![[:alnum:]])(?:onderwijs\p{L}*|school\p{L}*|enseignement|scolaire\p{L}*|[ée]coles?|schul\p{L}*|education|tuition)(?![[:alnum:]]))(?=.*(?<![[:alnum:]])(?:maximumfactuur\p{L}*|maf|maximum\s+[àa]\s+facturer|factures?\s+maximales?|maximum\s+(?:billing|invoices?)|h(?:ö|oe)chstrechnung\p{L}*|h(?:ö|oe)chstgrenze\s+f(?:ü|ue)r\s+(?:krankheits|gesundheits)\p{L}*)(?![[:alnum:]])).*\z/imu

    def self.maf_year_block(year, schedule)
      bands = schedule[:bands].map { |band, amount| "#{band} EUR: #{amount} EUR" }.join('; ')
      shares = schedule[:chronic_shares]&.map { |share_year, amount| "#{share_year}: #{amount} EUR" }&.join('; ')
      condition = if shares
                    '; voorwaarde: eenzelfde gezinslid droeg in elk van de twee voorgaande jaren ten minste het bedrag van ' \
                      "dat jaar aan persoonlijke aandelen (#{shares}), of heeft het statuut chronische aandoening " \
                      '(art. 37undecies, § 2, en 37vicies/1)'
                  end
      ["MAXIMUMFACTUUR #{year} (RIZIV):",
       "- Inkomens-MAF, maximumbedrag aan persoonlijke aandelen per gezin volgens het gezinsinkomen: #{bands}.",
       "- Sociale MAF (gezin van rechthebbenden op de verhoogde tegemoetkoming): #{schedule[:social]} EUR.",
       "- Kind jonger dan 19 jaar, ongeacht het gezinsinkomen: #{schedule[:child]} EUR.",
       "- Chronisch zieken: het maximumbedrag daalt met #{schedule[:chronic_reduction]} EUR (een vermindering, geen " \
       "plafond)#{condition}."].join("\n")
    end

    def self.maf_note(schedules = MAF_SCHEDULES, checked_on: MAF_CHECKED_ON)
      newest = schedules.keys.max
      <<~NOTE.strip
        OPGELET: de bedragen in art. 37octies (450 euro voor de sociale MAF), 37undecies (250 tot 1.800 euro, inkomensgrenzen
        van 11.120 tot 34.700 euro, 650 euro voor een kind) en de vermindering van 100 euro zijn wettelijke basisbedragen;
        ze worden elk jaar aangepast (art. 37quaterdecies). Noem ze nooit als de bedragen van een bepaald jaar.
        #{schedules.sort.reverse.map { |year, schedule| maf_year_block(year, schedule) }.join("\n")}
        Het gezinsinkomen is dat van het tweede jaar vóór het jaar van de MAF (art. 37duodecies, § 1).
        TOEPASSING: kies het jaar waarover de vraag gaat en noem het. #{newest} is het laatst bevestigde jaar (gecontroleerd op
        #{leefloon_date(checked_on)}): voor een later jaar staan de bedragen niet in deze bronnen; zeg dat en geef de bedragen
        van #{newest} als laatst bevestigde. Een maximumbedrag (plafond) en de vermindering voor chronisch zieken zijn
        verschillende dingen. Noem nooit een bedrag dat hier niet staat.
        Bron: #{MAF_SOURCE_URL}
      NOTE
    end
    # Contesting a traffic fine (Sol 2026-11-20 10:14:49Z, #2231): a deterministic key.
    TRAFFIC_FINE_TOPIC_KEY = 'verkeersboete_betwisten'
    # Withdrawal from an off-premises contract (Sol 2026-11-23 06:49:36Z, #1151 "Wat zijn mijn rechten bij colportage
    # (huis-aan-huisverkoop)?": with the same six cards as before, an answer let the 14 days start on the day of signing
    # or receipt). A deterministic key, matched by the pattern that pins arts. VI.67, VI.69 and VI.71.
    OFF_PREMISES_TOPIC_KEY = 'herroeping_buiten_verkoopruimten'

    # The Montreal Convention's limits (Sol 2026-11-20 16:20:33Z, #1137: "Wat zijn mijn rechten bij een
    # vliegtuigvertraging?" gave 4,150 SDR as the current limit for delay). The published text (2003A15226, art. 21 and
    # 22) keeps the 1999 amounts; art. 24 has the depositary (ICAO) review them every five years. ICAO's notice "2024
    # Revised Limits of Liability Under the Montreal Convention 1999" (read in full on 2026-11-20) gives the limits in
    # force as of 28 December 2024. NEXT REVIEW (art. 24, 1, five years after 2024): read ICAO's new notice, update the
    # amounts and MONTREAL_LIMITS_CHECKED_ON.
    MONTREAL_LIMITS_TOPIC_KEY = 'montreal_aansprakelijkheid'
    MONTREAL_LIMITS_SOURCE_URL = 'https://www.icao.int/sites/default/files/secretariat/legal/LEB%20Treaty%20Collection%20' \
                                 'Documents/2024_Revised_Limits_of_Liability_Under_the_Montreal_Convention_of_1999_en.pdf'
    MONTREAL_LIMITS_CHECKED_ON = Date.new(2026, 11, 20)
    # A flight together with a delay, a flight together with baggage, or the Convention by name. Not a train, a hotel
    # theft ("vol de bagages" names no flight) or a refugee ("vluchteling"). Also matched on the downcased question.
    MONTREAL_FLIGHT_WORD = /(?<![[:alnum:]])(?:vlucht(?:en|vertraging\p{L}*|annul\p{L}*)?|vliegtuig\p{L}*|luchtvaart\p{L}*|flights?|airlines?|planes?|avions?|compagnies?\s+a[ée]riennes?|fl[üu]g\p{L}*)(?![[:alnum:]])/iu
    MONTREAL_PATTERN = Regexp.union(
      /(?<![[:alnum:]])(?:verdrag\s+van\s+montr[ée]al|montr[ée]al[-\s]?verdrag|convention\s+de\s+montr[ée]al|montreal(?:er)?\s+(?:convention|[üu]bereinkommen))(?![[:alnum:]])/iu,
      /\A(?=.*(?:#{MONTREAL_FLIGHT_WORD.source}|(?<![[:alnum:]])vols?(?![[:alnum:]])))(?=.*(?:vertraging|vertraagd|te\s+laat|(?<![[:alnum:]])late(?![[:alnum:]])|delay|retard|versp[äa]t)).*\z/imu,
      /\A(?=.*#{MONTREAL_FLIGHT_WORD.source})(?=.*(?:bagage|baggage|luggage|valises?|gep[äa]ck)).*\z/imu
    )

    def self.montreal_limits_note(checked_on: MONTREAL_LIMITS_CHECKED_ON)
      <<~NOTE.strip
        OPGELET: de bedragen in de gepubliceerde tekst van het Verdrag van Montreal zijn de oorspronkelijke bedragen van 1999
        (art. 21: 100.000; art. 22, 1: 4.150; art. 22, 2: 1.000; art. 22, 3: 17 per kilogram, in bijzondere trekkingsrechten,
        BTR). De depositaris (ICAO) herziet ze volgens art. 24. Sinds 28 december 2024 gelden:
        - vertraging bij het vervoer van passagiers (art. 22, 1): 6.303 BTR per passagier;
        - bagage, bij vernieling, verlies, beschadiging of vertraging (art. 22, 2): 1.519 BTR per passagier;
        - goederen (art. 22, 3): 26 BTR per kilogram;
        - dood of letsel (art. 21): 151.880 BTR per passagier, het bedrag tot waar de vervoerder zijn aansprakelijkheid
          niet kan beperken of uitsluiten.
        TOEPASSING: noem bij een aansprakelijkheidsgrens het bedrag dat sinds 28 december 2024 geldt
        (gecontroleerd op #{leefloon_date(checked_on)}) en noem de bedragen van 1999 nooit als de huidige grenzen.
        Noem nooit een bedrag dat hier niet staat.
        Bron: ICAO, 2024 Revised Limits of Liability Under the Montreal Convention 1999, #{MONTREAL_LIMITS_SOURCE_URL}
      NOTE
    end

    def self.deterministic_topic_keys(question)
      text = question.to_s
      keys = []
      keys << TRAINING_CLAUSE_TOPIC_KEY if text.match?(TRAINING_CLAUSE_PATTERN)
      keys << GUARANTEED_PAY_TOPIC_KEY if text.match?(FocusedTopicSourceScope::GUARANTEED_PAY_PATTERN)
      keys << CAPITAL_GAINS_TOPIC_KEY if text.match?(FisconetSearch::CAPITAL_GAINS_TAX_PATTERN)
      keys << RENTAL_INCOME_TOPIC_KEY if text.match?(FisconetSearch::RENTAL_INCOME_TAX_PATTERN)
      keys << PENSION_APPEAL_TOPIC_KEY if text.match?(LegislationSearch::PENSION_APPEAL_PATTERN)
      keys << PERMIT_COUNCIL_TOPIC_KEY if text.match?(LegislationSearch::PERMIT_COUNCIL_PATTERN)
      keys << RECIDIVISM_TOPIC_KEY if text.match?(LegislationSearch::RECIDIVISM_PATTERN)
      keys << STATE_SECRET_TOPIC_KEY if text.match?(LegislationSearch::STATE_SECRET_PATTERN)
      keys << WITNESS_TOPIC_KEY if text.match?(LegislationSearch::PARTY_WITNESS_OBJECTION_PATTERN) ||
                                   text.match?(LegislationSearch::WITNESS_DUTY_PATTERN)
      keys << MAF_TOPIC_KEY if text.match?(MAF_PATTERN)
      keys << TRAFFIC_FINE_TOPIC_KEY if text.match?(LegislationSearch::TRAFFIC_FINE_CONTEST_PATTERN)
      keys << OFF_PREMISES_TOPIC_KEY if text.match?(LegislationSearch::OFF_PREMISES_PATTERN)
      keys << MONTREAL_LIMITS_TOPIC_KEY if text.match?(MONTREAL_PATTERN)
      keys
    end

    def self.required_official_topic_keys(question)
      keys = []
      keys << GDPR_PROCESSOR_TOPIC_KEY if gdpr_processor_question?(question)
      keys << GDPR_RETENTION_TOPIC_KEY if gdpr_retention_question?(question)
      keys << GDPR_DIRECT_MARKETING_TOPIC_KEY if gdpr_direct_marketing_question?(question)
      keys << GDPR_COMMERCIAL_WEBSITE_TOPIC_KEY if gdpr_commercial_website_question?(question)
      keys << GDPR_BREACH_TOPIC_KEY if gdpr_breach_question?(question)
      keys << GDPR_CONTROLLER_TOPIC_KEY if gdpr_controller_question?(question)
      keys
    end

    def self.gdpr_breach_question?(question)
      GdprBreachSources.topic?(question)
    end

    def self.gdpr_controller_question?(question)
      GdprControllerSources.topic?(question)
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

    # Sol 2026-11-22 19:11:40Z: a reader who asks about the Belgian act of 30 July 2018 beside the GDPR may get that act
    # cited for its own clauses; the GDPR's definition still comes from the GDPR
    BELGIAN_PRIVACY_ACT = /(?<![[:alpha:]])(?:belgisch\p{L}*|belges?|belgian|belgischen?)[[:space:]]+(?:\p{L}+[[:space:]]+){0,3}?
                            (?:wet|wetgeving|privacywet|kaderwet|loi|act|law|legislation|gesetz\p{L}*)(?![[:alpha:]])|
                            wet[[:space:]]+van[[:space:]]+30[[:space:]]+juli[[:space:]]+2018|loi[[:space:]]+du[[:space:]]+30[[:space:]]+juillet[[:space:]]+2018|
                            gesetz\p{L}*[[:space:]]+vom[[:space:]]+30\.?[[:space:]]+juli[[:space:]]+2018|act[[:space:]]+of[[:space:]]+30[[:space:]]+july[[:space:]]+2018|
                            kaderwet[[:space:]]+gegevensbescherming|loi-cadre|2018040581/iux

    def self.belgian_privacy_act_asked?(question)
      question.to_s.match?(BELGIAN_PRIVACY_ACT)
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
                                    when GDPR_BREACH_TOPIC_KEY
                                      [GDPR_BREACH_OFFICIAL_SOURCES, GDPR_BREACH_REQUIRED_ARTICLES]
                                    when GDPR_CONTROLLER_TOPIC_KEY
                                      [GDPR_CONTROLLER_OFFICIAL_SOURCES, GDPR_CONTROLLER_REQUIRED_ARTICLES]
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

    # [url, article number, point] of each record: art. 4's points 7 and 8 share the URL and article number
    def self.required_official_units_for(topic_key, language:)
      official_sources_for(topic_key, language: language).map do |source|
        [source.fetch(:url), source.fetch(:article_number), source[:point]]
      end
    rescue KeyError
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
      corrected_breach_edition =
        source[:official_source_topic] == GDPR_BREACH_TOPIC_KEY &&
        source[:official_edition] == GDPR_BREACH_OFFICIAL_EDITION &&
        uri.query == "uri=CELEX:#{GDPR_BREACH_OFFICIAL_EDITION}" &&
        GDPR_BREACH_REQUIRED_ARTICLES.include?(article_number) &&
        source[:article_text] == GDPR_BREACH_OFFICIAL_TEXTS.fetch(source.fetch(:language).downcase, {})[article_number]
      processor_texts = GDPR_PROCESSOR_OFFICIAL_SOURCES.fetch(source.fetch(:language).downcase, [])
                                                       .to_h { |record| [record[:article_number], record[:article_text]] }
      corrected_processor_edition =
        source[:official_source_topic] == GDPR_PROCESSOR_TOPIC_KEY &&
        source[:official_edition] == GDPR_PROCESSOR_OFFICIAL_EDITION &&
        uri.query == "uri=CELEX:#{GDPR_PROCESSOR_OFFICIAL_EDITION}" &&
        GDPR_PROCESSOR_REQUIRED_ARTICLES.include?(article_number) &&
        source[:article_text] == processor_texts[article_number]
      corrected_controller_edition =
        source[:official_source_topic] == GDPR_CONTROLLER_TOPIC_KEY &&
        source[:official_edition] == GDPR_CONTROLLER_OFFICIAL_EDITION &&
        uri.query == "uri=CELEX:#{GDPR_CONTROLLER_OFFICIAL_EDITION}" &&
        GDPR_CONTROLLER_REQUIRED_ARTICLES.include?(article_number) &&
        source[:article_text] == GDPR_CONTROLLER_OFFICIAL_TEXTS.fetch(source.fetch(:language).downcase, {})[article_number]

      source.fetch(:source) == 'eur_lex' &&
        source.fetch(:official_source_id) == GDPR_PROCESSOR_OFFICIAL_SOURCE_ID &&
        source.fetch(:authority) == 'EUR-Lex' &&
        uri.scheme == 'https' && uri.host == 'eur-lex.europa.eu' && uri.userinfo.nil? && uri.port == 443 &&
        uri.path == "/legal-content/#{source.fetch(:language)}/TXT/HTML/" &&
        (original_edition || corrected_marketing_edition || corrected_website_edition || corrected_breach_edition ||
         corrected_processor_edition || corrected_controller_edition) &&
        uri.fragment == "art_#{article_number}" &&
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
        label: 'Gewaarborgd loon bij ziekte - Art. 52-71 Arbeidsovereenkomstenwet',
        # Sol 2026-11-19 22:47:08Z (#1732): an answer blended the worker categories. Read in full on 2026-11-20: arts. 52,
        # 70 and 71 (1978070303), cao nr. 12bis (1979022660, workers) and cao nr. 13bis (1979022661, employees hired
        # for less than three months; its "op proef" predates the 2014 abolition of the trial clause, which also took
        # those words out of art. 71), arts. 2 to 4 of each.
        # Sol 2026-11-20 07:32:27Z: the live answer still headlined a capped 60% for days 8 to 14, the employer's
        # statutory part, so the note now opens with what the answer must give first.
        indexation_note: <<~NOTE.strip
          GEWAARBORGD LOON BIJ ZIEKTE OF ONGEVAL VAN GEMEEN RECHT: HOUD DE CATEGORIEËN UIT ELKAAR.
          Begin het antwoord met de regels per categorie hieronder. Voor de arbeider is het bedrag van dag 8 tot 14
          samen 85,88% (60% volgens art. 52 plus 25,88% volgens cao nr. 12bis): geef de 60% van art. 52 nooit als het
          percentage dat de arbeider krijgt. Leg voor dag 15 tot 30 de verdeling uit: het ziekenfonds betaalt zijn
          uitkering en de werkgever het aanvullende bedrag van de cao.
          - Bediende aangeworven voor onbepaalde tijd, voor een bepaalde tijd van ten minste drie maanden of voor een
            duidelijk omschreven werk van ten minste drie maanden (art. 70): het normale loon gedurende de eerste 30
            dagen.
          - Arbeider (art. 52, § 1, en cao nr. 12bis): dag 1 tot 7 het normale loon. Dag 8 tot 14: 60% van het loon onder
            de loongrens van de ziekte- en invaliditeitsverzekering (art. 52) plus 25,88% (cao nr. 12bis), samen 85,88%,
            en 85,88% van het deel boven die grens, alles ten laste van de werkgever. Vanaf dag 15 betaalt het
            ziekenfonds zijn uitkering en betaalt de werkgever tot dag 30 het aanvullende bedrag van de cao: 25,88%
            onder de loongrens en 85,88% erboven.
          - Bediende aangeworven voor een bepaalde tijd van minder dan drie maanden of voor een duidelijk omschreven werk
            van minder dan drie maanden (art. 71 en cao nr. 13bis): dag 1 tot 7 het normale loon. Dag 8 tot 14: 60% plus 26,93%, samen 86,93% onder de loongrens, en 86,93% erboven. Vanaf dag 15
            de uitkering van het ziekenfonds plus tot dag 30 het aanvullende bedrag van de werkgever: 26,93% onder de
            loongrens en 86,93% erboven.
          - Voor de arbeider en voor de bediende van art. 71 gaat het recht pas in na een maand ononderbroken dienst bij
            dezelfde onderneming (art. 52, § 1). Voor de arbeider is het niet opnieuw verschuldigd bij een nieuwe
            ongeschiktheid binnen de eerste acht weken na het einde van de vorige, behalve voor het restant van de
            eerste veertien dagen of bij een andere ziekte of een ander ongeval (art. 52, § 2, sinds 1 januari 2026).
        NOTE
      },
      # Sol 2026-11-19 22:47:08Z (#1737): an answer required both the hours and
      # the value of Art. 22bis, § 4. training_clause_directive states the "or"
      # and the current amounts.
      TRAINING_CLAUSE_TOPIC_KEY => {
        numac: '1978070303',
        article_patterns: ['Art. 22bis'],
        label: 'Scholingsbeding - Art. 22bis Arbeidsovereenkomstenwet'
      },

      # ── Social Security ─────────────────────────────────────────────────
      'leefloon' => {
        numac: '2002022559',
        article_patterns: ['Art. 14'],
        label: 'Leefloon - Art. 14 Leefloonwet',
        # The indexed amounts come from the POD MI circulars (LEEFLOON_SCHEDULES).
        # Sol 2026-11-19 22:59:36Z (#1704): until 1.1.78 this note still gave
        # the amounts of 1 March 2026 as current.
        indexation_note: leefloon_note
      },
      'werkloosheid' => {
        numac: '1991013192',
        article_patterns: ['Art. 100', 'Art. 101', 'Art. 102', 'Art. 103', 'Art. 108', 'Art. 114', 'Art. 115'],
        label: 'Werkloosheidsuitkering - Art. 100-115 Werkloosheidsbesluit',
        # #337 (Sol 2026-11-22 08:38:00Z): Art. 115 holds the 1999 base amounts, and the answer printed them as the
        # current minima. The note gives the indexed minima with their first day and manual check, and is dropped
        # once the newest schedule is past that check (IndexedAmounts).
        indexation_note: IndexedAmounts.context_note,
        note_stale_after: IndexedAmounts.fresh_until
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
      # Capital gains on financial assets, crypto included (#2675): the exemptions and the assets; the
      # directive (capital_gains_directive) adds the rate, the computation and the indexed amounts.
      'meerwaardebelasting' => {
        numac: '1992041050',
        article_patterns: ['Art. 96/2', 'Art. 92'],
        label: 'Meerwaarden op financiële activa - Art. 92 en 96/2 WIB92',
        fisconet_document_type: 'WIB 92'
      },
      # Rental income of a built property (#2673); the directive (rental_income_directive) separates the
      # figures on the return from the taxable base.
      'huurinkomsten' => {
        numac: '1992041050',
        article_patterns: ['Art. 7', 'Art. 13', 'Art. 518'],
        label: 'Huurinkomsten - Art. 7, 13 en 518 WIB92',
        fisconet_document_type: 'WIB 92'
      },
      # Contesting a pension decision (#1934): the Charter's period; the directive
      # (pension_appeal_directive) sets it against KB nr. 50 art. 66.
      'pensioen_beroep' => {
        numac: '1995022286',
        article_patterns: ['Art. 23'],
        label: 'Beroepstermijn - Art. 23 Handvest van de sociaal verzekerde'
      },
      # Witnesses (catalogue 1671, 2876): the civil rules; the directive (witness_directive) adds the
      # investigating judge's summons (Sv. art. 80-81, pinned).
      'getuigen' => {
        numac: '1967101055',
        article_patterns: ['Art. 915', 'Art. 916', 'Art. 925', 'Art. 926', 'Art. 928', 'Art. 929'],
        label: 'Getuigen in burgerlijke zaken - Art. 915-929 Gerechtelijk Wetboek'
      },
      # The health-care maximumfactuur: the statutory rules, and the RIZIV amounts per year (MAF_SCHEDULES).
      'maximumfactuur' => {
        numac: '1994071451',
        article_patterns: ['Art. 37octies', 'Art. 37undecies'],
        label: 'Maximumfactuur - Art. 37octies en 37undecies GVU-wet',
        indexation_note: maf_note
      },
      # Contesting a traffic fine (#2231): the payment order; the directive (traffic_fine_directive) adds the
      # earlier stages and art. 65ter, which never came into force.
      'verkeersboete_betwisten' => {
        numac: '1968031601',
        article_patterns: ['Art. 65/1'],
        label: 'Bevel tot betalen - Art. 65/1 Wegverkeerswet'
      },
      # The Montreal Convention (#1137): art. 19 (delay) and 22 (the limits of its published text); the limits in
      # force since 28 December 2024 are in montreal_limits_note, before the articles.
      MONTREAL_LIMITS_TOPIC_KEY => {
        numac: '2003A15226',
        article_patterns: ['Art. 19', 'Art. 22'],
        label: 'Verdrag van Montreal - Art. 19 en 22',
        indexation_note: montreal_limits_note
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
      # Off-premises contracts (#1151): art. VI.67 sets the period, and off_premises_withdrawal_directive, before the
      # article, says how to count it. Arts. VI.69 (the notice) and VI.71 (the return) reach the context as pinned
      # articles, so they are not repeated here.
      OFF_PREMISES_TOPIC_KEY => {
        numac: '2013A11134',
        article_patterns: ['Art. VI.67'],
        label: 'Herroepingstermijn buiten verkoopruimten - Art. VI.67 Wetboek Economisch Recht'
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
      GDPR_BREACH_TOPIC_KEY => {
        official_source_key: GDPR_BREACH_TOPIC_KEY,
        labels: GDPR_BREACH_SOURCE_LABELS
      },
      GDPR_CONTROLLER_TOPIC_KEY => {
        official_source_key: GDPR_CONTROLLER_TOPIC_KEY,
        labels: GDPR_CONTROLLER_SOURCE_LABELS
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
      # The Raad voor Vergunningsbetwistingen (#2065): art. 105; the directive (permit_council_directive) keeps the
      # objection requirement GwH 46/2019 annulled out of the answer.
      'raad_vergunningsbetwistingen' => {
        numac: '2014036510',
        article_patterns: ['Art. 105'],
        label: 'Raad voor Vergunningsbetwistingen - Art. 105 Omgevingsvergunningsdecreet'
      },
      # Recidivism (#1988): Book I art. 60; the directive (recidivism_directive) gives the subparagraphs in force
      # since 1 September 2026, which the consolidated text and its note do not show.
      'herhaling_strafrecht' => {
        numac: '2024002052',
        article_patterns: ['Art. 60'],
        label: 'Herhaling - Art. 60 Strafwetboek (boek I)'
      },
      # Receiving a state secret: Book II art. 586; the directive (state_secret_directive) gives the article in
      # force since 1 September 2026, which the consolidated text does not show.
      'staatsgeheim_ontvangen' => {
        numac: '2024002088',
        article_patterns: ['Art. 586'],
        label: 'Onbevoegd ontvangen van een staatsgeheim - Art. 586 Strafwetboek (boek II)'
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
    #
    # Audited version: Art. 37/2 as amended by the law of 3 June 2026
    # (2026201577, arts. 2 and 3, in force 1 August 2026), with its § 1/1
    # (law of 18 May 2026, art. 24, in force 1 June 2026), as the corpus rows
    # (NL and FR) read since 2026-10-16. Until 1.1.78 these were the 2018
    # brackets, so from that day the guard refused the live text and the note
    # fell silent (Sol 2026-11-19 22:47:08Z, #1721). The markers after the
    # brackets are the growth rules and § 1/1.
    NOTICE_PERIOD_TIERS = {
      1 => {
        employer: [
          ['een', 'minder dan zes maanden'],
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
          ['een', 'minder dan zes maanden'],
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
          'vanaf eenentwintig jaar ancienniteit wordt de opzeggingstermijn verder opgebouwd met een week per begonnen jaar ancienniteit',
          'voor arbeidsovereenkomsten waarvan de uitvoering, zoals overeengekomen door de werkgever en de werknemer, aanvangt ' \
          'vanaf 1 juni 2026, bedraagt de opzeggingstermijn voor werknemers met zeventien jaar of meer ancienniteit, in afwijking ' \
          'van paragraaf 1, 52 weken en wordt hij niet meer verder opgebouwd'
        ]
      },
      2 => {
        employer: [
          ['une', 'moins de six mois'],
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
          ['une', 'moins de six mois'],
          ['trois', 'entre six mois et moins de douze mois'],
          ['quatre', 'entre douze mois et moins de dix-huit mois'],
          ['cinq', 'entre dix-huit mois et moins de vingt-quatre mois'],
          ['six', 'entre deux ans et moins de quatre ans'],
          ['sept', 'entre quatre ans et moins de cinq ans'],
          ['neuf', 'entre cinq ans et moins de six ans'],
          ['dix', 'entre six ans et moins de sept ans'],
          ['douze', 'entre sept ans et moins de huit ans'],
          ['treize', "huit ans d'anciennete ou plus"]
        ],
        growth: [
          "a partir de cinq ans d'anciennete, le delai de preavis augmente ensuite sur la base de trois semaines par annee d'anciennete entamee",
          "a partir de la vingtieme annee d'anciennete, le delai de preavis augmente ensuite de deux semaines par annee d'anciennete entamee",
          "a partir de vingt-et-un ans d'anciennete, le delai de preavis augmente ensuite sur la base d'une semaine par annee d'anciennete entamee",
          "pour les contrats de travail dont l'execution, telle que convenue par l'employeur et le travailleur, debute a partir du " \
          "1er juin 2026, le delai du preavis pour les travailleurs comptant dix-sept ans d'anciennete ou plus est, par derogation " \
          "au paragraphe 1er, de 52 semaines et il n'augmente plus"
        ]
      }
    }.freeze

    # Art. 5 of the law of 3 June 2026: its brackets below six months' seniority
    # apply only to contracts whose execution starts from 1 August 2026 (art. 6:
    # its entry into force); an earlier contract keeps the 2018 brackets below
    # six months. Sol 2026-11-20 01:17:34Z: a start date in the question decides
    # exactly; a seniority alone is counted up to the notice (today unless the
    # question dates it) and names both brackets only while an earlier start
    # is possible.
    NOTICE_AMENDMENT_DATE = Date.new(2026, 8, 1)

    NOTICE_WEEK_WORDS = {
      'nl' => %w[week weken], 'fr' => %w[semaine semaines], 'de' => %w[Woche Wochen], 'en' => %w[week weeks]
    }.freeze

    NOTICE_MONTH_NAMES = {
      'nl' => %w[januari februari maart april mei juni juli augustus september oktober november december],
      'fr' => %w[janvier février mars avril mai juin juillet août septembre octobre novembre décembre],
      'de' => %w[Januar Februar März April Mai Juni Juli August September Oktober November Dezember],
      'en' => %w[January February March April May June July August September October November December]
    }.freeze

    NOTICE_TRANSITION_COPY = {
      'nl' => 'Overgangsregel (art. 5 wet van 3 juni 2026): is de uitvoering van de arbeidsovereenkomst vóór 1 augustus 2026 ' \
              'begonnen, dan gelden onder zes maanden anciënniteit nog de vroegere termijnen: opzegging door de werkgever ' \
              '%<employer>s, door de werknemer %<employee>s.',
      'fr' => "Disposition transitoire (art. 5 de la loi du 3 juin 2026) : si l'exécution du contrat a commencé avant le " \
              "1er août 2026, les anciens délais s'appliquent encore en dessous de six mois d'ancienneté : préavis donné par " \
              "l'employeur %<employer>s, par le travailleur %<employee>s.",
      'de' => 'Übergangsregel (Art. 5 des Gesetzes vom 3. Juni 2026): Hat die Ausführung des Arbeitsvertrags vor dem ' \
              '1. August 2026 begonnen, gelten bei weniger als sechs Monaten Betriebszugehörigkeit noch die früheren Fristen: ' \
              'Kündigung durch den Arbeitgeber %<employer>s, durch den Arbeitnehmer %<employee>s.',
      'en' => 'Transitional rule (Art. 5 of the Law of 3 June 2026): if performance of the employment contract began before ' \
              '1 August 2026, the earlier periods still apply below six months of seniority: notice by the employer ' \
              '%<employer>s, by the employee %<employee>s.'
    }.freeze

    NOTICE_EARLIER_BRACKETS_COPY = {
      'nl' => 'Art. 5 wet van 3 juni 2026: deze arbeidsovereenkomst begon vóór 1 augustus 2026, dus gelden onder zes maanden ' \
              'anciënniteit de vroegere termijnen; de waarden hierboven zijn die termijnen.',
      'fr' => "Art. 5 de la loi du 3 juin 2026 : ce contrat a commencé avant le 1er août 2026 ; en dessous de six mois " \
              "d'ancienneté, les anciens délais s'appliquent donc, et les valeurs ci-dessus sont ces délais.",
      'de' => 'Art. 5 des Gesetzes vom 3. Juni 2026: Dieser Arbeitsvertrag hat vor dem 1. August 2026 begonnen; bei weniger ' \
              'als sechs Monaten Betriebszugehörigkeit gelten daher die früheren Fristen, und die obigen Werte sind diese Fristen.',
      'en' => 'Art. 5 of the Law of 3 June 2026: this contract began before 1 August 2026, so below six months of seniority ' \
              'the earlier periods apply, and the figures above are those periods.'
    }.freeze

    # Arts. 67 to 69 of the law of 26 December 2013 (2013012289): a dismissal by
    # the employer of a worker whose contract began before 1 January 2014 has a
    # notice that is the sum of two parts, the first for the seniority on
    # 31 December 2013 under the rules of that date, the second for the
    # seniority from 1 January 2014 under Art. 37/2 (Sol 2026-11-19 23:34:21Z:
    # #1752, #1770 and #1792 gave one figure). Whole months of seniority can
    # leave the start on either side of that date (Sol 2026-11-20 01:17:34Z: on
    # 2026-11-20, 154 months covers 21 December 2013 to 20 January 2014); the
    # note then gives both conditions and asks for the start date.
    SINGLE_STATUS_DATE = Date.new(2014, 1, 1)

    NOTICE_PRE_2014_PARTS = {
      'nl' => 'de opzeggingstermijn bij ontslag door de werkgever de som van twee delen: deel 1 voor de anciënniteit op ' \
              '31 december 2013, volgens de regels die op die datum golden (voor een bediende met een jaarloon boven €32.254 ' \
              'op die datum: één maand per begonnen jaar anciënniteit, minimum drie maanden, tenzij er toen een geldige ' \
              'clausule over de opzeggingstermijn bestond); deel 2 voor de anciënniteit vanaf 1 januari 2014, volgens ' \
              'art. 37/2 (%<when>s: %<part_two>s)',
      'fr' => "le préavis en cas de licenciement par l'employeur est la somme de deux parties : la première pour l'ancienneté " \
              'acquise au 31 décembre 2013, selon les règles applicables à cette date (pour un employé dont la rémunération ' \
              "annuelle dépassait 32.254 euros à cette date : un mois par année d'ancienneté entamée, avec un minimum de trois " \
              "mois, sauf clause valable relative au délai de préavis existant alors) ; la seconde pour l'ancienneté acquise " \
              "à partir du 1er janvier 2014, selon l'article 37/2 (%<when>s : %<part_two>s)",
      'de' => 'die Kündigungsfrist bei einer Kündigung durch den Arbeitgeber die Summe zweier Teile: Teil 1 für die ' \
              'Betriebszugehörigkeit am 31. Dezember 2013 nach den an diesem Tag geltenden Regeln (für einen Angestellten mit ' \
              'einem Jahreslohn über 32.254 Euro an diesem Tag: ein Monat je angefangenes Dienstjahr, mindestens drei Monate, ' \
              'sofern damals keine gültige Klausel zur Kündigungsfrist bestand); Teil 2 für die Betriebszugehörigkeit ab dem ' \
              '1. Januar 2014 nach Art. 37/2 (%<when>s: %<part_two>s)',
      'en' => 'the notice for a dismissal by the employer is the sum of two parts: part 1 for the seniority on 31 December ' \
              '2013, under the rules that applied on that date (for an employee whose annual pay exceeded EUR 32,254 on that ' \
              'date: one month per started year of seniority, at least three months, unless a valid notice clause existed ' \
              'then); part 2 for the seniority from 1 January 2014, under Article 37/2 (%<when>s: %<part_two>s)'
    }.freeze

    # The line opens the note: the contract began before 2014 (stated or implied), or it may have (open). The Art. 37/2
    # employer figure below it is then not the total (Sol 2026-11-20 03:14:30Z, #1792: a live answer opened with it).
    NOTICE_PRE_2014_COPY = {
      'nl' => {
        stated: 'Art. 67-69 wet van 26 december 2013: deze arbeidsovereenkomst begon vóór 1 januari 2014. Daarom is %<parts>s. ' \
                'Begin het antwoord met deze regel van twee delen. Geef geen totaal zolang deel 1 niet vaststaat, en noem de ' \
                'gegevens die daarvoor nodig zijn: het statuut (arbeider of bediende) en het loon op 31 december 2013.',
        implied: 'Art. 67-69 wet van 26 december 2013: deze anciënniteit wijst op een arbeidsovereenkomst die vóór 1 januari ' \
                 '2014 begon. Daarom is %<parts>s. Begin het antwoord met deze regel van twee delen. Geef geen totaal zolang ' \
                 'deel 1 niet vaststaat, en noem de gegevens die daarvoor nodig zijn: de datum van indiensttreding, het ' \
                 'statuut (arbeider of bediende) en het loon op 31 december 2013.',
        open: 'Art. 67-69 wet van 26 december 2013: deze anciënniteit laat niet uitmaken of de arbeidsovereenkomst vóór of ' \
              'vanaf 1 januari 2014 begon (indiensttreding tussen %<earliest>s en %<latest>s). Begon ze vóór 1 januari 2014, ' \
              'dan is %<parts>s. Begon ze op of na 1 januari 2014, dan geldt art. 37/2 voor de volledige anciënniteit (zie ' \
              'hieronder). Begin het antwoord met deze twee voorwaarden en vraag naar de datum van indiensttreding.'
      },
      'fr' => {
        stated: 'Art. 67 à 69 de la loi du 26 décembre 2013 : ce contrat a commencé avant le 1er janvier 2014. Dès lors, ' \
                '%<parts>s. Commencez la réponse par cette règle des deux parties. Ne donnez pas de total tant que la ' \
                "première partie n'est pas établie, et indiquez les données nécessaires : le statut (ouvrier ou employé) et " \
                'la rémunération au 31 décembre 2013.',
        implied: 'Art. 67 à 69 de la loi du 26 décembre 2013 : cette ancienneté indique un contrat qui a commencé avant le ' \
                 '1er janvier 2014. Dès lors, %<parts>s. Commencez la réponse par cette règle des deux parties. Ne donnez ' \
                 "pas de total tant que la première partie n'est pas établie, et indiquez les données nécessaires : la date " \
                 "d'entrée en service, le statut (ouvrier ou employé) et la rémunération au 31 décembre 2013.",
        open: 'Art. 67 à 69 de la loi du 26 décembre 2013 : cette ancienneté ne permet pas de savoir si le contrat a commencé ' \
              "avant ou à partir du 1er janvier 2014 (entrée en service entre le %<earliest>s et le %<latest>s). S'il a " \
              "commencé avant le 1er janvier 2014, %<parts>s. S'il a commencé le 1er janvier 2014 ou après, l'article 37/2 " \
              "s'applique à toute l'ancienneté (voir ci-dessous). Commencez la réponse par ces deux conditions et " \
              "demandez la date d'entrée en service."
      },
      'de' => {
        stated: 'Art. 67 bis 69 des Gesetzes vom 26. Dezember 2013: Dieser Arbeitsvertrag hat vor dem 1. Januar 2014 ' \
                'begonnen. Daher ist %<parts>s. Die Antwort mit dieser Regel der zwei Teile beginnen. Keine Summe nennen, ' \
                'solange Teil 1 nicht feststeht, und die dafür nötigen Angaben nennen: den Status (Arbeiter oder ' \
                'Angestellter) und den Lohn am 31. Dezember 2013.',
        implied: 'Art. 67 bis 69 des Gesetzes vom 26. Dezember 2013: Diese Betriebszugehörigkeit deutet auf einen ' \
                 'Arbeitsvertrag hin, der vor dem 1. Januar 2014 begonnen hat. Daher ist %<parts>s. Die Antwort mit dieser ' \
                 'Regel der zwei Teile beginnen. Keine Summe nennen, solange Teil 1 nicht feststeht, und die dafür nötigen ' \
                 'Angaben nennen: das Eintrittsdatum, den Status (Arbeiter oder Angestellter) und den Lohn am 31. Dezember 2013.',
        open: 'Art. 67 bis 69 des Gesetzes vom 26. Dezember 2013: Diese Betriebszugehörigkeit lässt offen, ob der ' \
              'Arbeitsvertrag vor oder ab dem 1. Januar 2014 begonnen hat (Eintritt zwischen dem %<earliest>s und dem ' \
              '%<latest>s). Hat er vor dem 1. Januar 2014 begonnen, ist %<parts>s. Hat er am 1. Januar 2014 oder später ' \
              'begonnen, gilt Art. 37/2 für die gesamte Betriebszugehörigkeit (siehe unten). Die Antwort mit diesen zwei ' \
              'Bedingungen beginnen und nach dem Eintrittsdatum fragen.'
      },
      'en' => {
        stated: 'Arts. 67 to 69 of the Law of 26 December 2013: this employment contract began before 1 January 2014, so ' \
                '%<parts>s. Open the answer with this two-part rule. Give no total while part 1 is not established, and ' \
                'name the data it needs: the status (blue- or white-collar) and the pay on 31 December 2013.',
        implied: 'Arts. 67 to 69 of the Law of 26 December 2013: this seniority points to an employment contract that began ' \
                 'before 1 January 2014, so %<parts>s. Open the answer with this two-part rule. Give no total while part 1 ' \
                 'is not established, and name the data it needs: the start date, the status (blue- or white-collar) and ' \
                 'the pay on 31 December 2013.',
        open: 'Arts. 67 to 69 of the Law of 26 December 2013: this seniority leaves open whether the employment contract ' \
              'began before or from 1 January 2014 (a start between %<earliest>s and %<latest>s). If it began before ' \
              '1 January 2014, %<parts>s. If it began on or after 1 January 2014, Article 37/2 applies to the whole ' \
              'seniority (see below). Open the answer with these two conditions and ask for the start date.'
      }
    }.freeze

    # The employer line of a two-part case. A contract that certainly began before 2014 gets no figure: the
    # Art. 37/2 period for the whole seniority is not its notice, and an answer led with it all the same
    # (#1792, "67 weken" at 25 years, Sol 2026-11-20 07:32:27Z). In the boundary month the Art. 37/2 figure is
    # the answer for one of the two possible start dates, so it stays, with its condition.
    NOTICE_EMPLOYER_QUALIFIER = {
      'nl' => { before: 'geen totaal zolang deel 1 niet vaststaat; het is de som van deel 1 en deel 2 hierboven (art. 67)',
                open: '%<weeks>s als de overeenkomst op of na 1 januari 2014 begon; anders geldt de regel van twee delen ' \
                      'hierboven' },
      'fr' => { before: "pas de total tant que la partie 1 n'est pas établie ; c'est la somme des parties 1 et 2 ci-dessus " \
                        '(article 67)',
                open: "%<weeks>s si le contrat a commencé le 1er janvier 2014 ou après ; sinon, la règle des deux parties " \
                      "ci-dessus s'applique" },
      'de' => { before: 'keine Summe, solange Teil 1 nicht feststeht; es ist die Summe von Teil 1 und Teil 2 oben (Art. 67)',
                open: '%<weeks>s, wenn der Vertrag am 1. Januar 2014 oder später begonnen hat; sonst gilt die Regel der ' \
                      'zwei Teile oben' },
      'en' => { before: 'no total until part 1 is established; it is the sum of parts 1 and 2 above (Article 67)',
                open: '%<weeks>s if the contract began on or after 1 January 2014; otherwise the two-part rule above applies' }
    }.freeze

    # The employee line of a two-part case: since the law of 20 March 2023 (in force 28 October 2023) Art. 67
    # adds the two parts only when the employer gives notice ("in geval van ontslag door de werkgever", "en cas
    # de licenciement"; read in full 2026-11-20), so the employee's own notice is Art. 37/2, § 2.
    NOTICE_EMPLOYEE_QUALIFIER = {
      'nl' => '%<weeks>s (art. 37/2, § 2; de twee delen van art. 67 gelden alleen bij ontslag door de werkgever)',
      'fr' => "%<weeks>s (article 37/2, § 2 ; les deux parties de l'article 67 ne valent qu'en cas de licenciement)",
      'de' => '%<weeks>s (Art. 37/2 § 2; die zwei Teile von Art. 67 gelten nur bei Kündigung durch den Arbeitgeber)',
      'en' => '%<weeks>s (Article 37/2(2); the two parts of Article 67 apply only when the employer gives notice)'
    }.freeze

    # A notice question without a seniority (an overview or a table) still carries the transitional rules: the earlier
    # brackets below six months while a contract begun before 1 August 2026 can still be there, and the two parts of a
    # contract begun before 2014 (Sol 2026-11-20 03:14:30Z, #1753: a live table printed "minder dan 6 maanden | 1 week"
    # without its start-date condition). The earlier brackets, read in full: employer, Art. 37/2, § 1 as replaced by the
    # law of 26 March 2018 (2018011490, art. 2); employee, § 2 as inserted by the law of 26 December 2013 (2013012289,
    # art. 3).
    NOTICE_GENERAL_COPY = {
      'nl' => {
        head: '[Overgangsregels bij art. 37/2: vermeld ze bij elk overzicht van de opzeggingstermijnen]',
        under_six: 'Minder dan zes maanden anciënniteit: één week voor beide partijen geldt alleen voor ' \
                   'arbeidsovereenkomsten waarvan de uitvoering vanaf 1 augustus 2026 begon (art. 5 wet van 3 juni 2026). ' \
                   'Voor een overeenkomst die vóór die datum begon, gelden nog de vroegere termijnen: opzegging door de ' \
                   'werkgever 1 week (minder dan 3 maanden), 3 weken (3 tot 4 maanden), 4 weken (4 tot 5 maanden) en 5 weken ' \
                   '(5 tot 6 maanden); door de werknemer 1 week (minder dan 3 maanden) en 2 weken (3 tot 6 maanden). Geef ' \
                   'in een tabel of overzicht beide groepen weer.',
        cap: 'Art. 37/2, § 1/1 (wet van 18 mei 2026, sinds 1 juni 2026): voor elke arbeidsovereenkomst waarvan de ' \
             'uitvoering vanaf 1 juni 2026 begint, ook in augustus 2026 of later, bedraagt de opzeggingstermijn bij ' \
             'opzegging door de werkgever voor een werknemer met zeventien jaar of meer anciënniteit 52 weken en wordt ' \
             'hij niet meer verder opgebouwd. De datum van 1 augustus 2026 (art. 5 wet van 3 juni 2026) gaat alleen ' \
             'over de termijnen bij minder dan zes maanden anciënniteit.',
        pre_2014: 'Ontslag door de werkgever van een werknemer wiens arbeidsovereenkomst vóór 1 januari 2014 begon ' \
                  '(art. 67-69 wet van 26 december 2013): dan is %<parts>s. Vermeld die regel vóór een totaal bij een ' \
                  'lange anciënniteit.'
      },
      'fr' => {
        head: "[Dispositions transitoires de l'article 37/2 : à mentionner dans tout aperçu des délais de préavis]",
        under_six: "Moins de six mois d'ancienneté : une semaine pour les deux parties ne vaut que pour les contrats dont " \
                   "l'exécution a commencé à partir du 1er août 2026 (art. 5 de la loi du 3 juin 2026). Pour un contrat qui " \
                   "a commencé avant cette date, les anciens délais s'appliquent encore : préavis donné par l'employeur " \
                   '1 semaine (moins de 3 mois), 3 semaines (3 à 4 mois), 4 semaines (4 à 5 mois) et 5 semaines (5 à 6 mois) ; ' \
                   'par le travailleur 1 semaine (moins de 3 mois) et 2 semaines (3 à 6 mois). Dans un tableau ou un ' \
                   'aperçu, indiquez les deux groupes.',
        cap: "Art. 37/2, § 1er/1 (loi du 18 mai 2026, depuis le 1er juin 2026) : pour tout contrat dont l'exécution " \
             "débute à partir du 1er juin 2026, y compris en août 2026 ou plus tard, le délai de préavis donné par " \
             "l'employeur à un travailleur comptant dix-sept ans d'ancienneté ou plus est de 52 semaines et il " \
             "n'augmente plus. La date du 1er août 2026 (art. 5 de la loi du 3 juin 2026) ne concerne que les délais " \
             "pour moins de six mois d'ancienneté.",
        pre_2014: "Licenciement par l'employeur d'un travailleur dont le contrat a commencé avant le 1er janvier 2014 " \
                  '(art. 67 à 69 de la loi du 26 décembre 2013) : %<parts>s. Mentionnez cette règle avant tout total pour ' \
                  'une longue ancienneté.'
      },
      'de' => {
        head: '[Übergangsregeln zu Art. 37/2: bei jeder Übersicht der Kündigungsfristen nennen]',
        under_six: 'Weniger als sechs Monate Betriebszugehörigkeit: eine Woche für beide Parteien gilt nur für ' \
                   'Arbeitsverträge, deren Ausführung ab dem 1. August 2026 begonnen hat (Art. 5 des Gesetzes vom 3. Juni ' \
                   '2026). Für einen Vertrag, der vor diesem Datum begonnen hat, gelten noch die früheren Fristen: ' \
                   'Kündigung durch den Arbeitgeber 1 Woche (weniger als 3 Monate), 3 Wochen (3 bis 4 Monate), 4 Wochen ' \
                   '(4 bis 5 Monate) und 5 Wochen (5 bis 6 Monate); durch den Arbeitnehmer 1 Woche (weniger als 3 Monate) ' \
                   'und 2 Wochen (3 bis 6 Monate). In einer Tabelle oder Übersicht beide Gruppen nennen.',
        cap: 'Art. 37/2 § 1/1 (Gesetz vom 18. Mai 2026, seit dem 1. Juni 2026): Für jeden Arbeitsvertrag, dessen ' \
             'Ausführung ab dem 1. Juni 2026 beginnt, auch im August 2026 oder später, beträgt die Kündigungsfrist bei ' \
             'Kündigung durch den Arbeitgeber für einen Arbeitnehmer mit siebzehn Jahren Betriebszugehörigkeit oder mehr ' \
             '52 Wochen und steigt nicht weiter. Das Datum 1. August 2026 (Art. 5 des Gesetzes vom 3. Juni 2026) ' \
             'betrifft nur die Fristen bei weniger als sechs Monaten Betriebszugehörigkeit.',
        pre_2014: 'Kündigung durch den Arbeitgeber eines Arbeitnehmers, dessen Arbeitsvertrag vor dem 1. Januar 2014 ' \
                  'begonnen hat (Art. 67 bis 69 des Gesetzes vom 26. Dezember 2013): dann ist %<parts>s. Diese Regel bei ' \
                  'langer Betriebszugehörigkeit vor einer Summe nennen.'
      },
      'en' => {
        head: '[Transitional rules of Article 37/2: state them in every overview of notice periods]',
        under_six: 'Below six months of seniority: one week for both parties applies only to employment contracts whose ' \
                   'performance began on or after 1 August 2026 (Art. 5 of the Law of 3 June 2026). For a contract that ' \
                   'began before that date the earlier periods still apply: notice by the employer 1 week (under 3 ' \
                   'months), 3 weeks (3 to 4 months), 4 weeks (4 to 5 months) and 5 weeks (5 to 6 months); by the employee ' \
                   '1 week (under 3 months) and 2 weeks (3 to 6 months). In a table or overview, show both groups.',
        cap: 'Art. 37/2 § 1/1 (Law of 18 May 2026, since 1 June 2026): for every employment contract whose performance ' \
             'begins on or after 1 June 2026, including in August 2026 or later, the notice given by the employer to an ' \
             "employee with seventeen years' seniority or more is 52 weeks and does not grow further. The date of " \
             '1 August 2026 (Art. 5 of the Law of 3 June 2026) concerns only the periods below six months of seniority.',
        pre_2014: 'Dismissal by the employer of an employee whose contract began before 1 January 2014 (Arts. 67 to 69 of ' \
                  'the Law of 26 December 2013): %<parts>s. State that rule before any total for a long seniority.'
      }
    }.freeze

    NOTICE_WHEN_COPY = {
      'nl' => { today: 'bij een opzegging die vandaag wordt gegeven', dated: 'bij een opzegging op %<date>s' },
      'fr' => { today: "pour un préavis notifié aujourd'hui", dated: 'pour un préavis notifié le %<date>s' },
      'de' => { today: 'bei einer heute mitgeteilten Kündigung', dated: 'bei einer am %<date>s mitgeteilten Kündigung' },
      'en' => { today: 'for notice given today', dated: 'for notice given on %<date>s' }
    }.freeze

    # A date in the question counts as the start only beside an employment word, as the notice only beside a dismissal
    # word: "sinds 1 september ziek" is neither. Day-month-year in the four languages, month-day-year in English, and
    # numeric day/month/year or ISO dates.
    NOTICE_DATE_PATTERN = /
      (?<day>\d{1,2})(?:er|ste|de|e|\.)?\s+(?<month>[[:alpha:]]+)\s+(?<year>(?:19|20)\d{2})
      | (?<month2>[[:alpha:]]+)\s+(?<day2>\d{1,2}),?\s+(?<year2>(?:19|20)\d{2})
      | (?<day3>\d{1,2})[\/.-](?<month3>\d{1,2})[\/.-](?<year3>(?:19|20)\d{2})
      | (?<year4>(?:19|20)\d{2})-(?<month4>\d{1,2})-(?<day4>\d{1,2})
    /xi
    # The word right after a date decides first, then an act word before it ("ontslagen op"), then an employment verb
    # before it ("werk sinds"). Verb forms only: "werkgever" and "opzegtermijn" place no date.
    NOTICE_START_AFTER = /\A\s*(?:\p{L}+\s+){0,2}(?:in\s+dienst|aangeworven|begonnen|gestart|werk(?:e|t|en|te|ten)?|engag[ée]e?s?|embauch[ée]e?s?|besch[äa]ftigt|eingestellt|hired|started|employed)\b/i
    NOTICE_GIVEN_AFTER = /\A\s*(?:\p{L}+\s+){0,2}(?:ontslagen|opgezegd|licenci[ée]e?s?|gek[üu]ndigt|dismissed|fired)\b/i
    NOTICE_GIVEN_BEFORE = /\b(?:ontslagen|opgezegd|opzegging\s+(?:gekregen|ontvangen|gegeven)|licenci[ée]e?s?|pr[ée]avis\s+(?:notifi[ée]|re[çc]u|donn[ée])|gek[üu]ndigt|dismissed|fired|given\s+notice|notice\s+(?:was\s+)?(?:given|served))\b[^.?!;]{0,12}\b(?:op|le|am|on)\s+\z/i
    NOTICE_START_BEFORE = /\b(?:werk(?:e|t|en|te|ten)?|werkzaam|tewerkgesteld|aangeworven|begonnen|gestart|in\s+dienst|travaill\p{L}*|engag[ée]e?s?|embauch[ée]e?s?|en\s+service|besch[äa]ftigt|eingestellt|arbeite\p{L}*|work(?:s|ed|ing)?|employed|hired|started|joined)\b[^.?!;]{0,40}\b(?:sinds|vanaf|op|in|depuis(?:\s+le)?|le|seit(?:\s+dem)?|am|since|on)\s+\z/i

    # Cache TTL for DB lookups (1 hour)
    CACHE_TTL = 1.hour
    # Version segment of the formatted-fact cache key, bumped whenever the
    # formatted block changes shape. r47 (root 2026-10-19 21:40:06): the blocks
    # became complete, and a warm cache must never serve a block cut under the
    # old format after the deploy. The key stays bounded: version, topic and
    # language, never anything derived from the question. r48 (1.1.78): the
    # leefloon note gives the amounts of 1 September 2026, and a warm cache
    # must not serve the note of 1 March 2026 after the deploy.
    # r49 (1.1.79): the guaranteed-pay block opens with the note on the categories,
    # and the leefloon note dates every schedule.
    # r50 (1.1.80): the guaranteed-pay note opens with what the answer must give
    # first, and a two-part notice case shows no full-seniority employer figure.
    # r51 (1.1.82): a verified article whose newer version Justel still files as
    # future law is given in that version, with the day it took effect.
    FACT_CACHE_VERSION = 'r51'

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
      when TRAINING_CLAUSE_TOPIC_KEY
        prepend_fact_directive(base_result, training_clause_directive)
      when CAPITAL_GAINS_TOPIC_KEY
        prepend_fact_directive(base_result, capital_gains_directive)
      when RENTAL_INCOME_TOPIC_KEY
        prepend_fact_directive(base_result, rental_income_directive)
      when PENSION_APPEAL_TOPIC_KEY
        prepend_fact_directive(base_result, pension_appeal_directive)
      when PERMIT_COUNCIL_TOPIC_KEY
        prepend_fact_directive(base_result, permit_council_directive)
      when RECIDIVISM_TOPIC_KEY
        prepend_fact_directive(base_result, recidivism_directive)
      when STATE_SECRET_TOPIC_KEY
        prepend_fact_directive(base_result, state_secret_directive)
      when WITNESS_TOPIC_KEY
        prepend_fact_directive(base_result, witness_directive)
      when TRAFFIC_FINE_TOPIC_KEY
        prepend_fact_directive(base_result, traffic_fine_directive)
      when 'herroepingsrecht'
        prepend_fact_directive(base_result, withdrawal_period_directive)
      when OFF_PREMISES_TOPIC_KEY
        prepend_fact_directive(base_result, off_premises_withdrawal_directive)
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

    # FOD Werkgelegenheid, scholingsbeding page (read in full on 2026-11-19):
    # the annual pay of Art. 22bis, § 4, first dash, "moet hoger zijn dan
    # 44.447 € (bedrag van toepassing op 1 januari 2026)", pro rata for part-time
    # work, not for a training for a bottleneck occupation (§ 8). The corpus's
    # indexation notes stop at 33.221 EUR (2016). Valid for that year only.
    TRAINING_CLAUSE_PAY_FLOOR = { amount_nl: '44.447', year: 2026 }.freeze
    TRAINING_CLAUSE_SOURCE_URL =
      'https://werk.belgie.be/nl/themas/arbeidsovereenkomsten/uitvoering-van-de-arbeidsovereenkomst/scholingsbeding'

    # Art. 22bis, § 4, fourth dash: the clause is deemed not to exist "wanneer
    # de vorming geen duur van 80 uren bereikt of een waarde gelijk aan het
    # dubbel van het gemiddeld minimum maandinkomen", so it stands when EITHER
    # is reached (the statute: a value equal to twice the GGMMI suffices; FOD
    # writes "hoger dan"). Twice CURRENT_GGMMI is the 4.467,22 EUR the FOD page
    # gives from 1 July 2026, and it follows the next indexation and its
    # staleness.
    # Sol 2026-11-20 05:41:41Z (#2675): a crypto answer missed the 2026 capital gains regime. Every statement below was
    # read in full on 2026-11-20 in the corpus (W 06.04.2026, 2026002780, 35 articles, and its two KB of 18.05.2026)
    # and in Fisconet WIB 92 (art. 90, 92, 96/2, 102, 171, 178, 313). The indexed amounts for income 2026 are in
    # neither: they come from the FOD Financiën page read in full the same day, and lapse after stale_after, leaving
    # the statutory base amounts and the rule that they are indexed.
    def capital_gains_directive
      lines = [<<~DIRECTIVE.strip]
        MEERWAARDEN OP FINANCIËLE ACTIVA, CRYPTO INBEGREPEN: van toepassing vanaf 1 januari 2026 (art. 35 W 06.04.2026);
        de inkomsten van 2026 vormen aanslagjaar 2027.
        - Belastbaar als divers inkomen: meerwaarden die buiten het uitoefenen van een beroepswerkzaamheid en in het
          kader van normale verrichtingen van het beheer van een privévermogen zijn verwezenlijkt bij de overdracht
          onder bezwarende titel van financiële activa (art. 90, eerste lid, 9°, c), WIB 92). Cryptoactiva zijn
          financiële activa (art. 92, § 1, c)).
        - Tarief: 10 % (art. 171, 2°, e)), afzonderlijk belast, behalve wanneer de belasting volgens de artikelen 130
          tot 145 en 146 tot 156 op het geheel van de inkomsten lager is (art. 171, inleidende zin).
        - Vrijstelling: de eerste schijf van 4.855 euro (art. 96/2, eerste lid, 2°). Dat is het basisbedrag uit de wet;
          het wordt jaarlijks geïndexeerd (art. 178, § 1).
      DIRECTIVE
      if self.class.capital_gains_indexed_current?
        indexed = CAPITAL_GAINS_INDEXED
        lines << "- Geïndexeerd voor de inkomsten van #{indexed[:income_year]} (aanslagjaar #{indexed[:assessment_year]}): " \
                 "#{indexed[:exemption]} euro per persoon. Wie in een jaar minder meerwaarden verwezenlijkt, mag het niet " \
                 "gebruikte deel van de eerste schijf van #{indexed[:carry_forward]} euro (aanslagjaar " \
                 "#{indexed[:assessment_year]}) naar het volgende jaar overdragen, tot een vrijstelling van ten hoogste " \
                 "#{indexed[:five_year_total]} euro na vijf jaar (art. 96/2, eerste lid, 3°, en derde lid; bedragen van de " \
                 "FOD Financiën, #{indexed[:source_url]})."
      else
        lines << '- Overdracht: een aanvullende vrijgestelde schijf gelijk aan 480 euro min de vrijstelling die in een ' \
                 'vorig belastbaar tijdperk werd gebruikt, voor elke periode van 12 maanden waarin minder dan 480 euro werd ' \
                 'gebruikt, met ten hoogste 2.426 euro per belastbaar tijdperk (art. 96/2, eerste lid, 3°, en derde lid; ' \
                 'basisbedragen). De geïndexeerde bedragen voor het gevraagde jaar staan niet in deze bronnen: geef een ' \
                 'basisbedrag nooit als het geïndexeerde bedrag.'
      end
      lines << <<~DIRECTIVE.strip
        - Berekening: de ontvangen prijs min de aanschaffingswaarde (art. 102, § 1). Bij identieke activa geldt het eerst
          verkregen actief als eerst overgedragen; wordt de aanschaffingswaarde niet met bewijskrachtige gegevens
          bepaald, dan is de ontvangen prijs volledig belastbaar. Voor activa verkregen vóór 1 januari 2026 geldt de
          waarde op 31 december 2025 (art. 102, § 4); voor overdrachten tot 31 december 2030 mag de belastingplichtige
          op verzoek de door hem aangetoonde aanschaffingswaarde gebruiken. Minderwaarden uit hetzelfde belastbaar
          tijdperk binnen dezelfde categorie worden afgetrokken (art. 102, § 5).
        - Aangifte: meerwaarden op crypto moeten in de aangifte in de personenbelasting worden vermeld; de vrijstelling
          van aangifte voor inkomsten waarop roerende voorheffing werd ingehouden, geldt er niet voor (art. 313, eerste
          lid, 7°).
        - Andere gevallen: winst uit speculatie of uit verrichtingen buiten het normale beheer van een privévermogen
          valt onder art. 90, eerste lid, 1°, en wordt belast aan 33 % (art. 171, 1°, a)); voor financiële activa geldt
          het onweerlegbare vermoeden van normaal beheer (art. 90, eerste lid, 1°, tweede zin) niet. Art. 90, eerste
          lid, 9°, geldt alleen buiten het uitoefenen van een beroepswerkzaamheid.
        Noem bij elk bedrag het inkomstenjaar of aanslagjaar. Geef 4.855 euro nooit als de vrijstelling voor de
        inkomsten van 2026.
      DIRECTIVE
      lines.join("\n")
    end

    # Sol 2026-11-20 05:41:41Z (#2673): the figures a landlord enters on the return are not the taxable base. Read in
    # full on 2026-11-20: Fisconet WIB 92 art. 7, 8, 13 and 518, and the FOD Financiën pages on letting to a person who
    # does not use the property for a profession and on professional use. The coefficients lapse after stale_after.
    def rental_income_directive
      lines = [<<~DIRECTIVE.strip]
        HUURINKOMSTEN VAN EEN GEBOUWD ONROEREND GOED: onderscheid het bedrag dat op de aangifte komt van het bedrag
        waarop belast wordt.
        - Verhuur aan een natuurlijke persoon die het goed noch geheel noch gedeeltelijk voor zijn beroepswerkzaamheid
          gebruikt (art. 7, § 1, 2°, a), WIB 92): belastbaar is het kadastraal inkomen verhoogd met 40 %, en dat
          kadastraal inkomen is het geïndexeerde (art. 518). Op de aangifte vermeldt de verhuurder het niet-geïndexeerde
          kadastraal inkomen (code 1106/2106); het belastbare bedrag (geïndexeerd kadastraal inkomen x 1,4) wordt bij de
          aanslag berekend (FOD Financiën). Dezelfde grondslag (kadastraal inkomen verhoogd met 40 %) geldt voor de
          verhuur aan een rechtspersoon die geen vennootschap is, aan een gewestelijke huisvestingsmaatschappij of aan
          een erkende maatschappij voor sociale huisvesting, om het goed ter beschikking te stellen van een of meer
          natuurlijke personen die het uitsluitend als woning gebruiken (art. 7, § 1, 2°, bbis)).
        - Verhuur aan een natuurlijke persoon die het goed voor zijn beroep gebruikt, aan een rechtspersoon of aan een
          vennootschap (art. 7, § 1, 2°, c); FOD Financiën): het totale bedrag van de huurprijs en de huurvoordelen,
          niet lager dan het kadastraal inkomen verhoogd met 40 %. Op de huurprijs en de huurvoordelen gaat 40 %
          forfaitaire onderhouds- en herstellingskosten af, voor deze goederen ten hoogste twee derde van het kadastraal
          inkomen gerevaloriseerd met een coëfficiënt (art. 13). Op de aangifte: het niet-geïndexeerde kadastraal
          inkomen (code 1109/2109) en de brutohuur, dat is de huurprijs plus de huurvoordelen (code 1110/2110). Volgens
          de FOD Financiën wordt belast op het hoogste van de nettohuur (brutohuur min de begrensde 40 % kosten) en het
          geïndexeerde kadastraal inkomen x 1,4.
        - Stelt een geregistreerde huurovereenkomst de huur afzonderlijk vast voor het beroepsgedeelte en het andere
          gedeelte, dan worden de inkomsten van elk gedeelte afzonderlijk bepaald (art. 8).
      DIRECTIVE
      if self.class.rental_income_figures_current?
        figures = RENTAL_INCOME_FIGURES
        lines << "- Coëfficiënten volgens de FOD Financiën: indexatie van het kadastraal inkomen #{figures[:index]}; " \
                 "revalorisatie voor de begrenzing van de kosten #{figures[:revaluation]}. Voorbeeld van de FOD: " \
                 "#{figures[:example]}. Bronnen: #{figures[:source_urls].join(' en ')}."
      else
        lines << '- De indexatiecoëfficiënt van het kadastraal inkomen wordt elk jaar berekend (art. 518); de ' \
                 'coëfficiënt voor het gevraagde jaar staat niet in deze bronnen.'
      end
      lines << <<~DIRECTIVE.strip
        - De onroerende inkomsten worden belast volgens de progressieve tarieven. Gemeubelde verhuur en bijkomende
          diensten volgen afzonderlijke regels (de meubels als roerend inkomen, de diensten als divers inkomen), en een
          verhuur die een beroepswerkzaamheid is, levert beroepsinkomsten op (FOD Financiën).
        Zeg bij elk bedrag of het een aangiftebedrag of een belastbaar bedrag is, en voor welk inkomstenjaar.
      DIRECTIVE
      lines.join("\n")
    end

    # Sol 2026-11-20 00:21:18Z (#1934): an employee was given one month to contest a pension decision. Read in full on
    # 2026-11-20, NL and FR: Charter of the socially insured (1995022286) art. 23 and KB nr. 50 (1967102410) art. 66;
    # and the Federal Pensions Service page on contesting a decision (sfpd.fgov.be/nl/vraag/klachten).
    def pension_appeal_directive
      <<~DIRECTIVE.strip
        BEROEP TEGEN EEN PENSIOENBESLISSING: geef de termijn van drie maanden.
        - Art. 23, eerste lid, van het Handvest van de sociaal verzekerde (W 11.04.1995; dit lid sinds 1 januari 1997):
          het beroep tegen een beslissing van een instelling van sociale zekerheid over de toekenning, de betaling of de
          terugvordering van prestaties moet op straffe van verval worden ingesteld binnen drie maanden na de
          kennisgeving van de beslissing, of na de kennisneming ervan door de sociaal verzekerde als er geen kennisgeving
          was. Gunstiger termijnen uit specifieke wetgeving blijven gelden ("onverminderd gunstiger termijnen").
        - Art. 66 van het KB nr. 50 (rust- en overlevingspensioen voor werknemers) vermeldt nog "binnen de maand na de
          kennisgeving". Die kortere termijn is geen gunstiger termijn: geef nooit één maand als de termijn. De Federale
          Pensioendienst vermeldt eveneens 3 maanden.
        - Werknemerspensioen (en, volgens de Federale Pensioendienst, een pensioen van de Belgische spoorwegen): beroep
          bij de arbeidsrechtbank (art. 66 KB nr. 50), volgens de Federale Pensioendienst die van de hoofdverblijfplaats,
          met een verzoekschrift dat aangetekend wordt verstuurd, ter griffie wordt neergelegd of via e-Deposit wordt
          ingediend. Het beroep schorst de beslissing niet (art. 66, derde lid).
        - Ambtenarenpensioen: volgens de Federale Pensioendienst bij de rechtbank van eerste aanleg, per dagvaarding,
          zonder vaste termijn; achterstallen worden dan alleen terugbetaald voor de 10 jaar vóór het verzoek.
        - Vóór het beroep kan de betrokkene contact opnemen met de Pensioendienst, een klacht indienen of de
          Ombudsdienst Pensioenen inschakelen (Federale Pensioendienst).
        Officiële bron: https://www.sfpd.fgov.be/nl/vraag/klachten
      DIRECTIVE
    end

    # How to count the 14 days, shared by the distance and the off-premises directives below. Sol 2026-11-20 01:32:31Z
    # (#2116): an answer counted the period from the day of the event itself; Sol 2026-11-23 06:49:36Z (#1151): the
    # doorstep-sale answer of 1.1.93 let the 14 days start on the day of signing or receipt. Sol 2026-11-23 07:14:35Z
    # and 09:24:52Z, on 1.1.94: the examples need their year; the fourteenth day may fall on a weekend or a holiday;
    # utilities sold without a limited volume or set quantity count from the contract, a gas cylinder from its
    # possession; only goods of one order delivered separately count from the last one; the rule holds between a trader
    # and a consumer (a B2B purchase, a doorstep-selling permit); and a notice is in time when it is sent, while a live
    # answer required the trader to know of it before the end.
    # Read in full on 2026-11-23 (2013A11134): arts. VI.47, VI.49, VI.67 and VI.69 (NL and FR); arts. I.1, I.8, VI.48,
    # VI.50, VI.53, VI.68 and VI.71 (NL). For book VI an "onderneming" is defined by art. I.8, 39°, and both contracts
    # are contracts "tussen de onderneming en de consument" (I.8, 15° and 31°). Art. I.1, 9°, counts a Saturday as a
    # "werkdag", so the weekend rule below names the days instead of using that word. From our EU corpus (NL): Directive
    # 2011/83/EU recitals 40 and 41 and, consolidated to 27 September 2026, arts. 2, 9 and 11; Directive (EU) 2019/771
    # art. 2, consolidated to 31 July 2026. Regulation (EEC, Euratom) No 1182/71, which recital 41 applies to the
    # directive's periods, is not in our corpus: its Dutch text was read in full from the EU Publications Office (art.
    # 3(4): a period whose last day is a holiday, a Sunday or a Saturday ends with the following working day; art. 2(2):
    # working days are all days other than holidays, Sundays and Saturdays). The weekdays are the calendar's, and the
    # tests recompute every date.
    # Sol 2026-11-23 14:42:44Z: the late information was dated "binnen die twaalf maanden", the months after the end of
    # the ordinary period. VI.48 and VI.68, read again in full (NL and FR) the same day, count those twelve months from
    # "de in artikel VI.47 [VI.67], § 2, bedoelde dag", the starting point of the ordinary period; information given
    # later opens no new period of 14 days, and the period still ends twelve months after the ordinary one.
    # The text cites only articles of the WER. Measured on 2026-11-23 through the whole answer pipeline: an answer that
    # cites "art. 3, lid 4, van verordening (EEG, Euratom) nr. 1182/71", a regulation no source holds, was retried twice
    # and then withheld ("Antwoord niet weergegeven"); the regulation named without an article number was delivered.
    # So the rule names it without one, and the gas cylinder rests on art. I.1, 6°, and the wording of VI.47 and VI.67.
    def withdrawal_period_rules(title:, period:, extension:, notice:, contract:)
      <<~RULES.strip
        #{title} (art. #{period}, § 2, WER).
        VOOR WIE: het herroepingsrecht geldt voor een overeenkomst tussen een onderneming en een consument (art. I.8,
        #{contract}, WER). Een consument is een natuurlijke persoon die handelt voor doeleinden buiten zijn handels-,
        bedrijfs-, ambachts- of beroepsactiviteit (art. I.1, 2°, WER). Sloot de vrager de overeenkomst voor zo'n
        activiteit, of met een particulier, dan heeft hij dit herroepingsrecht niet: zeg dat. Blijkt het niet uit de vraag,
        zeg dan dat de regel alleen geldt voor een consument tegenover een onderneming.
        TELLEN: de termijn van 14 dagen "verstrijkt 14 dagen na":
        - bij een dienst, en bij de levering van water, gas of elektriciteit die niet gereed voor verkoop zijn gemaakt in
        een beperkt volume of in een bepaalde hoeveelheid, of van stadsverwarming: de dag waarop de overeenkomst wordt
        gesloten;
        - bij een verkoop: de dag waarop de consument, of een door hem aangewezen derde die niet de vervoerder is, de
        goederen fysiek in bezit neemt. Gas dat gereed is gemaakt voor verkoop in een bepaalde hoeveelheid, zoals een
        gasfles, valt niet onder de levering hierboven: een gasfles is een goed (een lichamelijke roerende zaak, art. I.1,
        6°, WER), en daarvoor telt de inbezitneming. Heeft de consument in dezelfde bestelling meerdere goederen besteld
        die afzonderlijk worden geleverd: de dag waarop hij het laatste goed in bezit neemt; bestaat de levering van een
        goed uit verschillende zendingen of onderdelen: de laatste zending of het laatste onderdeel; bij een overeenkomst
        voor de regelmatige levering van goederen gedurende een bepaalde periode: het eerste goed.
        Die dag is het vertrekpunt en telt zelf niet mee: de eerste dag van de termijn is de dag erna. Noem in het antwoord
        het vertrekpunt en de eerste getelde dag. Tel bij een verkoop niet vanaf de bestelling of de ondertekening.
        Voorbeeld dienst: overeenkomst gesloten op dinsdag 3 maart 2026; eerste dag woensdag 4 maart 2026, laatste dag
        dinsdag 17 maart 2026.
        Voorbeeld verkoop: overeenkomst gesloten op dinsdag 3 maart 2026, goed in bezit genomen op dinsdag 10 maart 2026;
        eerste dag woensdag 11 maart 2026, laatste dag dinsdag 24 maart 2026.
        WEEKEINDE OF FEESTDAG: valt de laatste dag op een zaterdag, een zondag of een wettelijke feestdag, dan verstrijkt de
        termijn aan het einde van de eerstvolgende dag die geen zaterdag, zondag of wettelijke feestdag is. Zo rekent
        verordening (EEG, Euratom) nr. 1182/71 de termijnen, en volgens richtlijn 2011/83/EU geldt zij voor de termijnen
        van die richtlijn. Die verordening staat niet in de bronnen: noem haar zonder artikelnummer. Voorbeeld: goed in
        bezit genomen op zaterdag 7 maart 2026; eerste dag zondag 8 maart 2026, veertiende dag zaterdag 21 maart 2026,
        zodat de termijn verstrijkt op maandag 23 maart 2026.
        GEEN INFORMATIE OVER HET HERROEPINGSRECHT (art. #{extension}, WER): heeft de onderneming die verplichte informatie
        niet gegeven, dan verstrijkt de termijn twaalf maanden na het einde van de gewone termijn. Geeft zij ze alsnog
        binnen twaalf maanden na het vertrekpunt dat hierboven onder TELLEN staat (dus niet na het einde van de gewone
        termijn), dan verstrijkt de termijn 14 dagen na de dag waarop de consument ze ontving. Geeft zij ze later, dan
        begint er geen nieuwe termijn van 14 dagen: de termijn verstrijkt nog altijd twaalf maanden na het einde van de
        gewone termijn. Voorbeeld dienst: overeenkomst gesloten op dinsdag 3 maart 2026, laatste dag van de gewone termijn
        dinsdag 17 maart 2026; zonder informatie verstrijkt de termijn op woensdag 17 maart 2027. Ontvangt de consument de
        informatie op maandag 1 maart 2027, binnen twaalf maanden na 3 maart 2026, dan verstrijkt de termijn op maandag
        15 maart 2027. Ontvangt hij ze pas op woensdag 10 maart 2027, meer dan twaalf maanden na 3 maart 2026, dan
        verstrijkt de termijn op woensdag 17 maart 2027, niet op woensdag 24 maart 2027.
        MEEDELEN (art. #{notice}, § 2 en § 4, WER): de herroeping is tijdig als de consument zijn mededeling verzendt
        voordat de termijn is verstreken; de bewijslast van de herroeping ligt bij de consument. Voorbeeld: verzendt hij
        ze op dinsdag 24 maart 2026, de laatste dag van het voorbeeld verkoop, en ontvangt de onderneming ze op donderdag
        26 maart 2026, dan is de herroeping tijdig. Schrijf niet dat de onderneming de herroeping vóór het einde van de
        termijn moet ontvangen of kennen.
      RULES
    end

    # The distance contract (arts. VI.47 to VI.53). Sol 2026-11-20 13:52:21Z (#2117, #1114): an answer let the trader
    # withhold the refund without the collection exception, and another gave the digital-content conditions as conditions
    # in every case. WER arts. VI.50 and VI.53 (read in full NL and FR on 2026-11-20; NL again on 2026-11-23): § 3 of
    # VI.50 opens "Behoudens wanneer de onderneming heeft aangeboden de goederen zelf af te halen"; VI.53, 1° and 13°,
    # attach the conditions to a contract that obliges the consumer to pay.
    def withdrawal_period_directive
      rules = withdrawal_period_rules(title: 'HERROEPINGSTERMIJN TELLEN', period: 'VI.47', extension: 'VI.48',
                                      notice: 'VI.49', contract: '15°')
      rest = <<~DIRECTIVE.strip
        TERUGBETALING (art. VI.50, § 3, WER): bij een verkoopovereenkomst mag de onderneming met de terugbetaling wachten
        tot zij alle goederen heeft teruggekregen of tot de consument heeft aangetoond dat hij ze heeft teruggezonden, naar
        gelang wat eerst valt, BEHALVE wanneer de onderneming heeft aangeboden de goederen zelf af te halen: dan mag zij
        niet wachten. Noem die uitzondering wanneer u het wachten met de terugbetaling vermeldt.
        DIGITALE INHOUD EN DIENSTEN (art. VI.53, 13° en 1°, WER): voor digitale inhoud die niet op een materiële drager
        wordt geleverd, kan de consument niet herroepen als de uitvoering is begonnen. De drie bijkomende voorwaarden
        (a) vooraf uitdrukkelijk ingestemd met de aanvang van de uitvoering tijdens de herroepingstermijn, b) erkend dat hij
        daarmee zijn herroepingsrecht verliest, c) bevestiging door de onderneming overeenkomstig art. VI.46, § 7) gelden
        alleen ingeval de overeenkomst de consument een betalingsverplichting oplegt. Voor een dienst vervalt het recht na
        de volledige uitvoering; legt de overeenkomst een betalingsverplichting op, dan alleen als de uitvoering begon met
        de voorafgaande uitdrukkelijke toestemming van de consument en hij erkende zijn herroepingsrecht te verliezen. Stel
        die voorwaarden nooit voor als voorwaarden die in elk geval gelden.
      DIRECTIVE
      "#{rules}\n#{rest}"
    end

    # The off-premises contract (#1151, arts. VI.67 to VI.71). The directive above only reaches a question that names
    # the withdrawal right, and it cites the distance contract's articles. Art. VI.71, § 1 (read in full NL on
    # 2026-11-23): the goods go back within 14 days after the day of the notice, unless the trader offered to collect
    # them; that period is separate from the withdrawal period.
    def off_premises_withdrawal_directive
      rules = withdrawal_period_rules(title: 'HERROEPINGSTERMIJN TELLEN BIJ EEN OVEREENKOMST BUITEN VERKOOPRUIMTEN',
                                      period: 'VI.67', extension: 'VI.68', notice: 'VI.69', contract: '31°')
      rest = <<~DIRECTIVE.strip
        TERUGZENDEN, EEN AFZONDERLIJKE TERMIJN (art. VI.71, § 1, WER): de consument zendt de goederen terug of overhandigt
        ze onverwijld en in elk geval binnen 14 dagen na de dag waarop hij zijn beslissing om te herroepen aan de
        onderneming heeft meegedeeld, tenzij de onderneming heeft aangeboden de goederen zelf af te halen. Voorbeeld:
        deelt hij de herroeping mee op dinsdag 17 maart 2026, dan kan hij de goederen terugzenden tot en met dinsdag
        31 maart 2026. Verwar die termijn niet met de herroepingstermijn zelf.
      DIRECTIVE
      "#{rules}\n#{rest}"
    end

    # Sol 2026-11-20 10:14:49Z (#2231): the answer must say which stage the reader is at. Read in full on 2026-11-20: Road
    # Traffic Act (1968031601) art. 65, 65/1 (NL and FR, with its future-law text) and 65ter, and Code of Criminal
    # Procedure (1808111901) art. 216bis.
    def traffic_fine_directive
      <<~DIRECTIVE.strip
        VERKEERSBOETE BETWISTEN: de regel hangt af van het stuk dat de lezer kreeg. Onderscheid de drie stadia en vraag
        welk stuk het is als dat niet uit de vraag blijkt.
        - Onmiddellijke inning (art. 65 Wegverkeerswet): bij een door de Koning aangewezen overtreding kan, als het feit
          geen schade aan derden veroorzaakte en met instemming van de overtreder, een som worden geheven. Door de betaling
          vervalt de strafvordering, tenzij het openbaar ministerie binnen een maand na de betaling kennis geeft van zijn
          voornemen die vordering in te stellen (art. 65, § 2).
        - Minnelijke schikking (art. 216bis Wetboek van strafvordering): de procureur des Konings kan de dader verzoeken
          een bepaalde geldsom te storten binnen de termijn die hij bepaalt: ten minste vijftien dagen en ten hoogste drie
          maanden. Betaling binnen die termijn doet de strafvordering vervallen.
        - Bevel tot betalen (art. 65/1 Wegverkeerswet): wordt de som van art. 216bis niet binnen de bepaalde termijn
          betaald, dan kan de procureur des Konings bevel geven tot betalen van de op de overtreding toepasselijke geldsom,
          verhoogd met 35 %. Wie het bevel ontving, of diens advocaat, kan binnen dertig dagen volgend op de dag van
          ontvangst betalen of beroep aantekenen bij de politierechtbank die bevoegd is volgens de plaats van de
          overtreding. Het bevel wordt geacht te zijn ontvangen de tiende werkdag na de dagtekening ervan (art. 65/1, § 1
          en § 2). Wie aantoont dat hij het bevel niet binnen die termijn kon kennen, kan nog beroep aantekenen binnen
          vijftien dagen na de dag waarop hij er kennis van kreeg of na de eerste daad van invordering (art. 65/1, § 8).
        - Art. 65ter Wegverkeerswet (ingevoegd in 2003) is niet in werking getreden; de geconsolideerde tekst vermeldt
          "Inwerkingtreding : onbepaald". Geef de termijn van veertien dagen en de kennisgeving op de tweede dag uit dat
          artikel nooit als geldende regel.
      DIRECTIVE
    end

    # Sol 2026-11-20 01:05:24Z (catalogue 1671 and 2876): keep the party's objection, the civil witness's duty and the
    # criminal summons apart. Judicial Code art. 915-916, 925-926, 928-929 and Code of Criminal Procedure art. 80-81, read
    # in full NL and FR on 2026-11-20.
    def witness_directive
      <<~DIRECTIVE.strip
        GETUIGEN: onderscheid wie de vraag stelt en in welke procedure.
        - Een partij die bezwaar heeft tegen het horen van een getuige (burgerlijke zaak): de rechter kan het
          getuigenbewijs toestaan als een partij aanbiedt een bepaald en ter zake dienend feit te bewijzen en het bewijs
          toelaatbaar is (art. 915 Ger.W.); hij kan ook ambtshalve getuigen laten horen (art. 916). De partij kan dus
          aanvoeren dat het feit niet bepaald of niet ter zake dienend is of dat het bewijs niet toelaatbaar is; de
          rechter beslist. Maak er geen bezwaar van tegen een weigering van de rechter om een getuige te horen.
        - Een opgeroepen getuige in een burgerlijke zaak: wie na een oproeping door de griffier niet verschijnt, kan op
          verzoek van een partij bij deurwaardersexploot worden gedagvaard (art. 925); een gedagvaarde getuige die niet
          verschijnt, wordt tot een geldboete veroordeeld (art. 926), en dezelfde geldboete geldt voor wie zonder wettige
          reden weigert de eed af te leggen of te getuigen (art. 928). Voert de getuige een wettige reden aan, zoals het
          beroepsgeheim, dan beslist de rechter (art. 929).
        - Een getuige die door de onderzoeksrechter is gedagvaard (strafonderzoek): hij moet verschijnen en aan de
          dagvaarding voldoen; anders kan de onderzoeksrechter de bij de wet bepaalde straf uitspreken en bevelen dat hij
          lichamelijk wordt gedwongen zijn getuigenis te komen afleggen (art. 80 Sv.). Wie na een tweede dagvaarding
          wettige redenen van verschoning voorlegt, kan van die straf worden ontheven (art. 81 Sv.).
        Blijkt niet uit de vraag of het om een burgerlijke zaak of een strafzaak gaat, zeg dan dat het antwoord daarvan
        afhangt en geef beide.
      DIRECTIVE
    end

    # Sol 2026-11-20 10:13:42Z (#2065). Read in full on 2026-11-20: Omgevingsvergunningsdecreet (2014036510) art. 105
    # (NL and FR) and art. 53 (NL), and GwH 14 March 2019, nr. 46/2019 (ECLI:BE:GHCC:2019:ARR.046).
    def permit_council_directive
      <<~DIRECTIVE.strip
        RAAD VOOR VERGUNNINGSBETWISTINGEN (omgevingsvergunning):
        - Beroep tegen een beslissing in laatste administratieve aanleg: art. 105 van het Omgevingsvergunningsdecreet.
          Wie beroep kan instellen staat in § 2, eerste lid (onder meer de vergunningsaanvrager en het betrokken publiek).
          Termijn: 45 dagen, op straffe van onontvankelijkheid, vanaf de dag na de betekening of, in de overige
          gevallen, na de eerste dag van de aanplakking (§ 3).
        - Geldende voorwaarde (§ 2, tweede lid): wie een voor hem nadelige vergunningsbeslissing niet heeft bestreden met
          het openstaande georganiseerd administratief beroep (art. 52), wordt geacht te hebben verzaakt aan zijn recht
          om zich tot de Raad voor Vergunningsbetwistingen te wenden.
        - Vernietigd: de geconsolideerde tekst van art. 105, § 2, en van art. 53 (administratief beroep) vermeldt nog
          dat het betrokken publiek alleen beroep kan instellen als het tijdens het openbaar onderzoek een standpunt,
          opmerking of bezwaar indiende. Het Grondwettelijk Hof heeft de bepalingen die dat invoegden (art. 133, 2°, en
          art. 151, 3°, van het decreet van 8 december 2017) vernietigd bij arrest nr. 46/2019 van 14 maart 2019
          (B.S. 9 april 2019) en de gevolgen niet gehandhaafd. Geef een bezwaar tijdens het openbaar onderzoek nooit
          als ontvankelijkheidsvoorwaarde.
        Bron: GwH 14 maart 2019, nr. 46/2019, /jurisprudence/ECLI:BE:GHCC:2019:ARR.046
      DIRECTIVE
    end

    # Sol 2026-11-20 01:05:24Z (#1988). Read in full on 2026-11-20, NL and FR unless noted: GwH 29 January 2026,
    # nr. 14/2026 (ECLI:BE:GHCC:2026:ARR.014, NL); Book I act (2024002052) art. 60 of the Code, art. 2 of the Code
    # (stored as Art.2.2) and the act's own art. 38 (stored as Art.38.2); Book II act (2024002088) art. 119 (stored as
    # Art.119.2, NL); law of 16 March 2026 (2026002189) arts. 19 and 127. The consolidated text of art. 60 (Justel, text
    # update through 2 April 2026) still prints both original subparagraphs and a note that the whole article was
    # annulled, and shows neither change made by art. 19.
    def recidivism_directive
      <<~DIRECTIVE.strip
        HERHALING, ART. 60 STRAFWETBOEK (BOEK I, IN WERKING SINDS 1 SEPTEMBER 2026):
        - De geconsolideerde tekst van art. 60 hieronder is verouderd. Zijn NOTA zegt dat het Grondwettelijk Hof "dit
          artikel" vernietigde, maar het beschikkend gedeelte van arrest nr. 14/2026 van 29 januari 2026 vernietigt
          alleen het tweede lid. Zeg nooit dat het hele artikel 60 vernietigd is of dat herhaling niet meer tot een
          zwaardere straf kan leiden.
        - Eerste lid (geldt): wordt de dader vervolgd voor een misdrijf waarop een straf van niveau 1 tot 6 staat, dan
          kan de rechter die straf verhogen naar het onmiddellijk hogere niveau als bij het plegen van het misdrijf nog
          geen vijf jaar verlopen waren sinds de dag waarop een vorige veroordeling in kracht van gewijsde is getreden.
          Die termijn wordt verlengd met de tijd waarin de gevangenisstraf of de behandeling onder vrijheidsberoving
          wordt uitgevoerd, behalve de periode onder elektronisch toezicht en de periodes van voorwaardelijke
          invrijheidsstelling, voorlopige invrijheidsstelling met het oog op verwijdering van het grondgebied of met
          het oog op overlevering en de invrijheidsstelling onder toezicht (die opsomming sinds art. 19, 1°, van de wet
          van 16 maart 2026). Het Hof oordeelde dat dit lid de artikelen 10 en 11 van de Grondwet niet schendt (B.56).
        - Tweede lid: het oorspronkelijke tweede lid gold alleen voor natuurlijke personen en is daarom vernietigd
          (B.58.1). Art. 19, 2°, van de wet van 16 maart 2026 heeft in de plaats een nieuw tweede lid ingevoegd: wordt
          de dader vervolgd voor een misdrijf waarop een straf van niveau 7 staat en werd hij eerder veroordeeld tot een
          straf van niveau 7 of 8, dan wordt de minimumstraf gebracht op een gevangenisstraf van tweeëntwintig jaar of
          een behandeling onder vrijheidsberoving van zeventien jaar voor natuurlijke personen en op een geldboete van
          2.080.000 euro voor rechtspersonen.
        - Feiten gepleegd vóór 1 september 2026: art. 2 van het Strafwetboek staat geen zwaardere straf toe dan die
          waarin de wet ten tijde van het misdrijf voorzag; bij een latere wijziging gelden de voor de dader meest
          gunstige bepalingen.
        Bronnen: GwH 29 januari 2026, nr. 14/2026, /jurisprudence/ECLI:BE:GHCC:2026:ARR.014; wet van 16 maart 2026,
        art. 19, /laws/2026002189
      DIRECTIVE
    end

    # Sol 2026-11-20 13:46:27Z. Read in full on 2026-11-20, NL and FR unless noted: GwH 29 January 2026, nr. 14/2026
    # (ECLI:BE:GHCC:2026:ARR.014, NL: B.103, B.112, dictum); Book II act (2024002088) art. 586 of the Code and the act's own
    # art. 119 (stored as Art.119.2); law of 16 March 2026 (2026002189) arts. 110 and 127; the 1867 Criminal Code
    # (1867060850) art. 120, which our corpus still prints in the wording of art. 71 of the act of 28 March 2024 without a
    # note, although the same dictum annuls that art. 71.
    def state_secret_directive
      <<~DIRECTIVE.strip
        STAATSGEHEIM ONBEVOEGD ONTVANGEN, ART. 586 STRAFWETBOEK (BOEK II, IN WERKING SINDS 1 SEPTEMBER 2026):
        - De geconsolideerde tekst van art. 586 hieronder is verouderd: hij geeft de tekst die het Grondwettelijk Hof
          vernietigde bij arrest nr. 14/2026 van 29 januari 2026. Die tekst stelde het ontvangen strafbaar met enkel een
          algemeen opzet ("opzettelijk"), wat volgens het Hof de vrijheid van meningsuiting en de persvrijheid onevenredig
          beperkte (B.112.2 en B.112.3).
        - Art. 110 van de wet van 16 maart 2026 heeft in de plaats een nieuw art. 586 ingevoegd: "Onbevoegd ontvangen van
          een staatsgeheim is het met het oogmerk afbreuk te doen aan de essentiële belangen van België of van een Staat
          waarmee België met het oog op een gemeenschappelijke verdediging door een internationale overeenkomst is
          verbonden, geheel of ten dele, in origineel of reproductie, aanschaffen of ontvangen, zonder bevoegd te zijn dit in
          ontvangst te nemen of er kennis van te nemen, van een staatsgeheim, alsook de poging om dit te doen." Straf van
          niveau 3. Noem beide: de essentiële belangen van België en die van een Staat waarmee België door zo'n
          overeenkomst verbonden is.
        - Feiten gepleegd vóór 1 september 2026: hetzelfde arrest vernietigde ook art. 71 van de wet van 28 maart 2024, dat
          art. 120 van het Strafwetboek van 1867 had vervangen. Art. 2 van het Strafwetboek staat geen zwaardere straf toe
          dan die waarin de wet ten tijde van het misdrijf voorzag; bij een latere wijziging gelden de voor de dader meest
          gunstige bepalingen.
        Bronnen: GwH 29 januari 2026, nr. 14/2026, /jurisprudence/ECLI:BE:GHCC:2026:ARR.014; wet van 16 maart 2026,
        art. 110, /laws/2026002189
      DIRECTIVE
    end

    def training_clause_directive
      lines = [<<~DIRECTIVE.strip]
        SCHOLINGSBEDING, ART. 22BIS, § 4, VIERDE STREEPJE: LEES DIT ALS "OF". Het beding is onbestaande "wanneer de
        vorming geen duur van 80 uren bereikt of een waarde gelijk aan het dubbel van het gemiddeld minimum
        maandinkomen". Die voorwaarde is dus vervuld als de vorming OFWEL minstens 80 uren duurt, OFWEL die waarde
        bereikt: één van beide volstaat, eis ze nooit allebei. De andere voorwaarden van § 4 gelden daarnaast.
        Bij een waarde precies gelijk aan het dubbel: de wet zegt "gelijk aan" (de voorwaarde is dan vervuld),
        de FOD Werkgelegenheid schrijft "hoger dan"; vermeld dat verschil met beide bronnen en stel geen
        andere drempel voor.
      DIRECTIVE
      unless self.class.ggmmi_stale?
        lines << "Het dubbel van het gemiddeld minimum maandinkomen bedraagt sinds #{CURRENT_GGMMI[:effective_nl]} " \
                 "€#{doubled_ggmmi_nl}."
      end
      if Date.current.year == TRAINING_CLAUSE_PAY_FLOOR[:year]
        lines << "Jaarloon (§ 4, eerste streepje) in #{TRAINING_CLAUSE_PAY_FLOOR[:year]}: hoger dan " \
                 "€#{TRAINING_CLAUSE_PAY_FLOOR[:amount_nl]}, pro rata voor deeltijdse werknemers; deze voorwaarde geldt " \
                 'niet voor een opleiding voor een knelpuntberoep (§ 8).'
      end
      lines << "Officiële bron: #{TRAINING_CLAUSE_SOURCE_URL}"
      lines.join("\n")
    end

    # CURRENT_GGMMI[:amount_nl] doubled, in the same Dutch notation.
    def doubled_ggmmi_nl
      euros, cents = (CURRENT_GGMMI[:amount_nl].delete('.').delete(',').to_i * 2).divmod(100)
      "#{euros.to_s.reverse.scan(/\d{1,3}/).join('.').reverse},#{format('%02d', cents)}"
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
      dates = notice_question_dates(question)
      reference = dates[:notice] || Date.current
      months = dates[:start] ? completed_months(dates[:start], reference) : seniority_months(question)
      return notice_period_general_note(notice_period_source_text) unless months

      notice_period_note(months, notice_period_source_text, start_date: dates[:start], notice_date: dates[:notice])
    end

    def notice_period_source_text
      Article.where(content_numac: '1978070303', language_id: @language_id)
             .where("LOWER(REPLACE(article_title, ' ', '')) = 'art.37/2'")
             .first&.article_text.to_s
    end

    # The note for a detected seniority, or nil unless source_text is the
    # audited Art. 37/2 (NOTICE_PERIOD_TIERS). start_date and notice_date are
    # the dates the question states; the notice is otherwise today.
    def notice_period_note(months, source_text, start_date: nil, notice_date: nil)
      return nil unless current_notice_period_source?(source_text)

      known = known_contract_date(start_date, notice_date)
      earlier = months < 6 && !known.nil? && known < NOTICE_AMENDMENT_DATE
      reference = notice_date || Date.current
      earliest = (reference << (months + 1)) + 1
      latest = reference << months
      basis = pre_2014_basis(start_date, earliest, latest)
      employer = notice_weeks_label(employer_notice_weeks(months, before_amendment: earlier))
      employee = notice_weeks_label(employee_notice_weeks(months, before_amendment: earlier))
      if basis
        qualifier = NOTICE_EMPLOYER_QUALIFIER.fetch(@language, NOTICE_EMPLOYER_QUALIFIER['nl'])
        employer = basis == :open ? format(qualifier.fetch(:open), weeks: employer) : qualifier.fetch(:before)
        employee = format(NOTICE_EMPLOYEE_QUALIFIER.fetch(@language, NOTICE_EMPLOYEE_QUALIFIER['nl']), weeks: employee)
      end
      text = notice_period_text(employer, employee, months / 12, months % 12)
      lead = basis ? [pre_2014_line(basis, reference, !notice_date.nil?, earliest, latest)] : []
      [*lead, text, *notice_period_exceptions(months, start_date: start_date, notice_date: notice_date)].join("\n")
    end

    # A notice question without a seniority: the transitional rules every overview of Art. 37/2 must carry
    # (NOTICE_GENERAL_COPY), the earlier brackets only while a contract begun before 1 August 2026 can still be
    # below six months.
    def notice_period_general_note(source_text)
      return nil unless current_notice_period_source?(source_text)

      copy = NOTICE_GENERAL_COPY.fetch(@language, NOTICE_GENERAL_COPY['nl'])
      lines = [copy[:head]]
      lines << copy[:under_six] if Date.current < (NOTICE_AMENDMENT_DATE >> 6)
      lines << copy[:cap]
      when_copy = NOTICE_WHEN_COPY.fetch(@language, NOTICE_WHEN_COPY['nl'])
      part_two = notice_weeks_label(employer_notice_weeks(completed_months(SINGLE_STATUS_DATE, Date.current)))
      parts = format(NOTICE_PRE_2014_PARTS.fetch(@language, NOTICE_PRE_2014_PARTS['nl']), when: when_copy[:today], part_two: part_two)
      lines << format(copy[:pre_2014], parts: parts)
      lines.join("\n")
    end

    # A date by which the contract had certainly begun: the stated start, or a
    # notice given before 1 August 2026 (no contract could begin after it).
    def known_contract_date(start_date, notice_date)
      start_date || (notice_date if notice_date && notice_date < NOTICE_AMENDMENT_DATE)
    end

    def notice_period_text(employer_weeks, employee_weeks, years, remainder_months)
      case @language
      when 'fr'
        <<~FACT.strip
          [Application déterministe de l'article 37/2 pour l'ancienneté demandée]
          Ancienneté détectée: #{years} an(s)#{" et #{remainder_months} mois" if remainder_months.positive?}.
          Préavis donné par l'employeur (§ 1): #{employer_weeks}.
          Préavis donné par le travailleur (§ 2): #{employee_weeks}.
          Ne confondez pas ces deux barèmes; si l'auteur du préavis n'est pas indiqué, mentionnez les deux.
        FACT
      when 'de'
        <<~FACT.strip
          [Deterministische Anwendung von Artikel 37/2 auf die angegebene Betriebszugehörigkeit]
          Erkannte Betriebszugehörigkeit: #{years} Jahr(e)#{" und #{remainder_months} Monate" if remainder_months.positive?}.
          Kündigung durch den Arbeitgeber (§ 1): #{employer_weeks}.
          Kündigung durch den Arbeitnehmer (§ 2): #{employee_weeks}.
          Diese beiden Tabellen nicht verwechseln; ist die kündigende Partei unklar, beide Werte nennen.
        FACT
      when 'en'
        <<~FACT.strip
          [Deterministic application of Article 37/2 to the stated seniority]
          Detected seniority: #{years} year(s)#{" and #{remainder_months} months" if remainder_months.positive?}.
          Notice by the employer (§ 1): #{employer_weeks}.
          Notice by the employee (§ 2): #{employee_weeks}.
          Do not confuse the two schedules; if the terminating party is unclear, state both.
        FACT
      else
        <<~FACT.strip
          [Deterministische toepassing van Art. 37/2 op de gevraagde anciënniteit]
          Herkende anciënniteit: #{years} jaar#{" en #{remainder_months} maanden" if remainder_months.positive?}.
          Opzegging door de werkgever (§ 1): #{employer_weeks}.
          Opzegging door de werknemer (§ 2): #{employee_weeks}.
          Verwar deze twee tabellen niet; als niet staat wie opzegt, vermeld beide.
        FACT
      end
    end

    def notice_weeks_label(weeks)
      singular, plural = NOTICE_WEEK_WORDS.fetch(@language, NOTICE_WEEK_WORDS['nl'])
      "#{weeks} #{weeks == 1 ? singular : plural}"
    end

    # The rules below six months' seniority, decided by the start date when the
    # question gives one (or by a notice before 1 August 2026) and otherwise by
    # the starts the seniority allows, counted back from the notice. The two
    # parts of a contract begun before 2014 open the note (notice_period_note).
    def notice_period_exceptions(months, start_date: nil, notice_date: nil)
      return [] unless months < 6

      reference = notice_date || Date.current
      earliest = (reference << (months + 1)) + 1
      known = known_contract_date(start_date, notice_date)
      if known
        known < NOTICE_AMENDMENT_DATE ? [NOTICE_EARLIER_BRACKETS_COPY.fetch(@language, NOTICE_EARLIER_BRACKETS_COPY['nl'])] : []
      elsif earliest < NOTICE_AMENDMENT_DATE
        [format(NOTICE_TRANSITION_COPY.fetch(@language, NOTICE_TRANSITION_COPY['nl']),
                employer: notice_weeks_label(employer_notice_weeks(months, before_amendment: true)),
                employee: notice_weeks_label(employee_notice_weeks(months, before_amendment: true)))]
      else
        []
      end
    end

    def pre_2014_basis(start_date, earliest, latest)
      return (start_date < SINGLE_STATUS_DATE ? :stated : nil) if start_date
      return :implied if latest < SINGLE_STATUS_DATE

      :open if earliest < SINGLE_STATUS_DATE
    end

    def pre_2014_line(basis, reference, dated, earliest, latest)
      when_copy = NOTICE_WHEN_COPY.fetch(@language, NOTICE_WHEN_COPY['nl'])
      notice_when = dated ? format(when_copy[:dated], date: notice_date_label(reference)) : when_copy[:today]
      part_two = notice_weeks_label(employer_notice_weeks(completed_months(SINGLE_STATUS_DATE, reference)))
      parts = format(NOTICE_PRE_2014_PARTS.fetch(@language, NOTICE_PRE_2014_PARTS['nl']), when: notice_when, part_two: part_two)
      format(NOTICE_PRE_2014_COPY.fetch(@language, NOTICE_PRE_2014_COPY['nl']).fetch(basis),
             parts: parts, earliest: notice_date_label(earliest), latest: notice_date_label(latest))
    end

    # Whole months from start to reference: a start of 31 December 2013 and one
    # of 1 January 2014 both have 154 on 20 November 2026.
    def completed_months(start, reference)
      months = ((reference.year - start.year) * 12) + (reference.month - start.month)
      months -= 1 if (start >> months) > reference
      [months, 0].max
    end

    def notice_date_label(date)
      month = NOTICE_MONTH_NAMES.fetch(@language, NOTICE_MONTH_NAMES['nl'])[date.month - 1]
      case @language
      when 'fr' then "#{date.day == 1 ? '1er' : date.day} #{month} #{date.year}"
      when 'de' then "#{date.day}. #{month} #{date.year}"
      else "#{date.day} #{month} #{date.year}"
      end
    end

    # The start and notice dates a question states, by the words beside them
    # (NOTICE_START_*, NOTICE_GIVEN_*). A start after the notice is dropped.
    def notice_question_dates(question)
      text = question.to_s
      found = {}
      text.to_enum(:scan, NOTICE_DATE_PATTERN).each do
        match = Regexp.last_match
        date = notice_match_date(match)
        next unless date

        role = notice_date_role(text[[match.begin(0) - 60, 0].max...match.begin(0)], text[match.end(0), 40].to_s)
        found[role] ||= date if role
      end
      found.delete(:start) if found[:start] && found[:start] > (found[:notice] || Date.current)
      found
    end

    def notice_date_role(before, after)
      return :start if after.match?(NOTICE_START_AFTER)
      return :notice if after.match?(NOTICE_GIVEN_AFTER) || before.match?(NOTICE_GIVEN_BEFORE)

      :start if before.match?(NOTICE_START_BEFORE)
    end

    def notice_match_date(match)
      year, month, day =
        if match[:year] then [match[:year], notice_month_number(match[:month]), match[:day]]
        elsif match[:year2] then [match[:year2], notice_month_number(match[:month2]), match[:day2]]
        elsif match[:year3] then [match[:year3], match[:month3], match[:day3]]
        else [match[:year4], match[:month4], match[:day4]]
        end
      return nil unless month

      Date.new(year.to_i, month.to_i, day.to_i)
    rescue Date::Error
      nil
    end

    def notice_month_number(name)
      wanted = notice_fold(name)
      NOTICE_MONTH_NAMES.each_value do |names|
        index = names.index { |month| notice_fold(month) == wanted }
        return index + 1 if index
      end
      nil
    end

    def notice_fold(word)
      word.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').downcase
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

    def employer_notice_weeks(months, before_amendment: false)
      return employer_notice_weeks_before_amendment(months) if before_amendment && months < 6
      return 1 if months < 6
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

    # Art. 37/2, § 1, before the law of 3 June 2026, below six months.
    def employer_notice_weeks_before_amendment(months)
      return 1 if months < 3
      return 3 if months < 4
      return 4 if months < 5

      5
    end

    def employee_notice_weeks(months, before_amendment: false)
      return months < 3 ? 1 : 2 if before_amendment && months < 6
      return 1 if months < 6
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
      # A version Justel still files as future law whose commencement has passed takes
      # the place of its plain row when it is newer (FutureLaw.in_force_versions, Sol
      # #2058); one that has not commenced, an article inserted without a commencement
      # (Sol #2231) and a listed code before its day are no facts.
      matching = FutureLaw.in_force_versions(matching)

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
        # emitted and the pending change is only named; a block whose commencement has
        # passed is the text (FutureLaw.in_force_text). Rows that are ENTIRELY future law
        # were already settled by the caller (FutureLaw.in_force_versions).
        text, commenced, future_block = FutureLaw.in_force_text(text)
        next if text.blank?

        pending = future_block && FutureLaw.effective_date(future_block)
        commenced ||= article.commenced_on if article.respond_to?(:commenced_on)

        # r47 (root 2026-10-19 18:59:40): the in-force text is emitted complete. This
        # channel overrides the retrieved evidence, so a cut here could drop a condition
        # even when the main context is whole; the orchestrator counts the whole emitted
        # verified-data block against the statutory allowance before generation.
        if future_block
          text += @language_id == 2 ? " [modification pas encore en vigueur#{pending ? " (#{pending})" : ''}]"
                                    : " [wijziging nog niet in werking#{pending ? " (vanaf #{pending})" : ''}]"
        end
        if commenced
          stamp = commenced.strftime('%d-%m-%Y')
          text += @language_id == 2 ? " [version en vigueur depuis le #{stamp}]" : " [versie in werking sinds #{stamp}]"
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
