# frozen_string_literal: true

require 'uri'

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
      /(?<![[:alpha:]])(?:avg|gdpr|rgpd|dsgvo|privacy|persoonsgegevens|personal data|donn[eé]es? (?:à caractère )?personnelles?|datenschutz|controller|responsable du traitement|verwerkingsverantwoordelijke)(?![[:alpha:]])/iu

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

    def self.gdpr_processor_question?(question)
      value = question.to_s
      return true if value.match?(GDPR_PROCESSOR_QUESTION_PATTERN)

      value.match?(GDPR_PROCESSOR_CONTEXTUAL_QUESTION_PATTERN) &&
        value.match?(GDPR_DATA_PROTECTION_CONTEXT_PATTERN)
    end

    def self.official_sources_for(topic_key, language:)
      return [] unless topic_key.to_s == GDPR_PROCESSOR_TOPIC_KEY

      sources = GDPR_PROCESSOR_OFFICIAL_SOURCES.fetch(language.to_s, [])
      return [] unless sources.map { |source| source.fetch(:article_number) }.sort == GDPR_PROCESSOR_REQUIRED_ARTICLES.sort
      return [] unless sources.all? { |source| valid_official_source?(source) }

      # Return shallow copies so response assembly cannot mutate the sealed
      # source records. All nested values are frozen scalars/arrays.
      sources.map(&:dup)
    rescue KeyError, URI::InvalidURIError
      []
    end

    def self.required_official_citations_for(topic_key, language:)
      return [] unless topic_key.to_s == GDPR_PROCESSOR_TOPIC_KEY

      GDPR_PROCESSOR_OFFICIAL_SOURCES.fetch(language.to_s, []).map do |source|
        [source.fetch(:url), source.fetch(:article_number)]
      end
    rescue KeyError
      []
    end

    def self.valid_official_source?(source)
      uri = URI.parse(source.fetch(:url))
      article_number = source.fetch(:article_number).to_s

      source.fetch(:source) == 'eur_lex' &&
        source.fetch(:official_source_id) == GDPR_PROCESSOR_OFFICIAL_SOURCE_ID &&
        source.fetch(:authority) == 'EUR-Lex' &&
        uri.scheme == 'https' && uri.host == 'eur-lex.europa.eu' && uri.userinfo.nil? && uri.port == 443 &&
        uri.path == "/legal-content/#{source.fetch(:language)}/TXT/HTML/" &&
        uri.query == 'uri=CELEX:32016R0679' && uri.fragment == "art_#{article_number}" &&
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
      'gdpr' => {
        numac: '2018040581',
        article_patterns: ['Art. 33', 'Art. 83', 'Art. 12', 'Art. 17'],
        label: 'Belgische Gegevensbeschermingswet van 30 juli 2018'
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
                      cache_key = "legal_fact_provider/#{topic_key}/lang_#{@language_id}"
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
      # 'Art. 3' match Art.30-39, Art.3bis, Art.3.1 — all DIFFERENT articles
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
      # "Art.3 TOEKOMSTIG RECHT" matches a request for Art. 3 — a space follows the 3 and
      # the boundary test passes. Injecting that as a verified fact would state a rule that
      # is not in force yet through the channel the prompt says overrides everything.
      matching = matching.reject do |article|
        FutureLaw.row_future?(variant: article.try(:article_variant),
                              title: article.article_title)
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

        # Cut a trailing future-law block off before the truncation below, or a long enough
        # article can lose the marker and keep the text it introduced. Rows that are ENTIRELY
        # future law were already rejected by the caller.
        in_force, future_block = FutureLaw.split(text)
        next if in_force.nil?

        text = in_force
        pending = future_block && FutureLaw.effective_date(future_block)

        # Truncate very long articles to avoid token bloat
        text = "#{text[0..3000]} [...]" if text.length > 3000
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
        # Splitting here also lands before the dedup key below and the 3000-char cut, so a
        # row is never deduped or truncated on words that are not in force.
        in_force, future_block = FutureLaw.split(text)
        next if in_force.nil?

        text = in_force
        pending = future_block && FutureLaw.effective_date(future_block)

        key = [article_number.to_s.downcase.delete('/'), text]
        next if seen[key]

        seen[key] = true

        text = "#{text[0..3000]} [...]" if text.length > 3000
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
