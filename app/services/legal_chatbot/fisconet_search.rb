# frozen_string_literal: true

module LegalChatbot
  # Searches FiscoNetPlus tax legislation (WIB 92, BTW-Wetboek, W.Reg., W.Succ.).
  # Includes tax question detection heuristic.
  #
  # FiscoNetPlus is the Belgian Federal Public Service Finance
  # tax code database, integrated in March 2026. It is the ONLY place the
  # consolidated tax codes live: the main laws DB has the BTW-Wetboek
  # (1969070305) and WIB 92 (1992041050) as empty shells with ZERO article
  # rows, so tax questions depend entirely on this backend.
  #
  # Retrieval: keyword search over tax_articles (primary). The FAISS vector
  # path (port 8768) is DISABLED by default: its index (Jan 2026) is keyed to
  # tax_articles AUTOINCREMENT ids from an old scrape, and the nightly scraper
  # renumbers ids on every merge — ~78% of index ids dangle and the rest
  # resolve to the WRONG articles (verified 2026-07-13: a VAT question
  # returned registration-duties articles). Re-enable via
  # FISCONET_FAISS_ENABLED=true only after the index is rebuilt keyed on a
  # stable identifier and regenerated per scrape.
  class FisconetSearch
    include TextProcessing

    FAISS_URL = ENV.fetch('FAISS_FISCONET_URL', 'http://localhost:8768')
    FISCONET_DB = ENV.fetch('FISCONET_DB', '/mnt/HC_Volume_104299669/embeddings/fisconet.sqlite3')
    FAISS_ENABLED = ENV.fetch('FISCONET_FAISS_ENABLED', 'false') == 'true'

    # Tax-related keywords for question classification
    TAX_KEYWORDS = [
      'belasting', 'belastingen', 'btw', 'tva', 'vat', 'tax', 'fiscal', 'fiscaal', 'fiscale', 'aftrekbaar', 'aftrek', 'belastingvermindering', 'belastingvrij', 'vennootschapsbelasting', 'personenbelasting', 'isoc', 'impôt', 'roerende', 'voorheffing', 'onroerende', 'kadastraal', 'registratie', 'successie', 'erfbelasting', 'schenkbelasting', 'erfrecht', 'schenking', 'factuur', 'facturatie', 'omzet', 'omzetbelasting', 'accijnzen', 'belastingaangifte', 'belastingplichtige', 'beroepskosten', 'kostenforfait', 'huwelijksquotiënt', 'huwelijksquotient', 'woon-werkforfait', 'kinderen ten laste', 'belastingschijf', 'pensioensparen', 'roerende voorheffing', 'voordeel alle aard', 'diverse inkomsten', 'huurinkomsten', 'steuer', 'einkommensteuer', 'mehrwertsteuer', 'körperschaftsteuer', 'erbschaftssteuer', 'steuererklärung', 'steuerpflichtig', 'income tax', 'corporate tax', 'inheritance tax', 'tax return', 'taxation', 'taxable', 'deductible', 'tax bracket', 'pension saving', 'rental income', 'impôt des sociétés', 'précompte', 'droits de succession', "droits d'enregistrement", 'déclaration fiscale', 'épargne-pension', 'revenus divers', 'revenus immobiliers'
    ].freeze

    FLANDERS_PATTERN = /(?<![[:alnum:]])(?:vlaanderen|vlaams(?:e)?|flandre|flamand(?:e)?|flandern|fl[aä]misch(?:e[rsnm]?)?|flanders|flemish)(?![[:alnum:]])/iu
    INHERITANCE_TAX_PATTERN = /(?<![[:alnum:]])(?:erfbelasting|successierecht(?:en)?|droits?\s+de\s+succession|erbschafts?steuer|inheritance\s+tax)(?![[:alnum:]])/iu
    COMPANY_CAR_TAX_PATTERN = /\A(?=.*(?:\bbedrijfswagen\b|\bvoiture\s+de\s+société\b|\bfirmenwagen\b|\bcompany\s+car\b|\bvoordeel\s+alle\s+aard\b.{0,40}\b(?:wagen|auto|voertuig)\b|\bavantage\s+de\s+toute\s+nature\b.{0,40}\b(?:véhicule|voiture)\b))(?=.*\b(?:belast\w*|belasting\w*|fisca\w*|voordeel\s+alle\s+aard|imp[oô]t\w*|fiscal\w*|avantage\s+de\s+toute\s+nature|steuer\w*|versteuer\w*|geldwerter\s+vorteil|tax\w*|benefit\s+in\s+kind)\b).*\z/im
    CRYPTO_TAX_PATTERN = /\A(?=.*\b(?:crypto|cryptomunten?|cryptovaluta|cryptowinst(?:en)?|cryptomonnaies?|cryptocurrenc(?:y|ies)|kryptowährung(?:en)?|bitcoin)\b)(?=.*(?:\b(?:belast\w*|belasting\w*|fisca\w*|diverse\s+inkomsten|meerwaard\w*|winsten?|inkomsten|imp[oô]t\w*|fiscal\w*|revenus?\s+divers|plus[-\s]?value\w*|gains?|tax\w*|income|steuer\w*|gewinn\w*)\b|\bcryptowinst(?:en)?\b)).*\z/im
    DIVERSE_INCOME_PATTERN = /\b(?:diverse\s+inkomsten|revenus\s+divers|sonstige\s+einkünfte|miscellaneous\s+income)\b/i

    # Question-token → tax-code filter (LIKE patterns applied to
    # tax_legislation.document_type / title). Steers retrieval to the right
    # code so a VAT question doesn't surface registration-duties articles.
    CODE_HINTS = [
      { question: /btw|tva\b|omzetbelasting|toegevoegde\s+waarde|mehrwertsteuer|\bvat\b/i,
        legislation: ['%btw%', '%toegevoegde waarde%', '%valeur ajoutée%'] },
      { question: /inkomstenbelasting|personenbelasting|vennootschapsbelasting|bedrijfsvoorheffing|\bwib\b|impôt des sociétés|einkommensteuer/i,
        legislation: ['%inkomstenbelasting%', '%wib%', '%impôts sur les revenus%'] },
      { question: /registratierecht|registratiebelasting|schenkbelasting|droits d.enregistrement|droits? de donation|registration tax|gift tax|registrierungssteuer|schenkungssteuer/i,
        legislation: ['%registratie%', '%enregistrement%', '%w.reg%'] },
      { question: /successie|erfbelasting|nalatenschap|droits de succession|erbschaft|inheritance tax|estate tax/i,
        legislation: ['%successie%', '%succession%', '%w.succ%'] }
    ].freeze

    # High-confidence tax concepts whose governing articles are otherwise
    # easily displaced by a different code containing the same vocabulary.
    ARTICLE_HINTS = [
      { question: /\A(?=.*\b(?:btw|tva|vat|mehrwertsteuer)\b)(?=.*\b(?:renovati\w*|verbouw\w*|rénovation\w*|renovation\w*)\b).*\z/im,
        document_types: ['kb 20'], articles: %w[A-XXXI A-XXXVIII] },
      { question: /\A(?=.*\b(?:btw|tva|vat|mehrwertsteuer)\b)(?=.*\b(?:afbraak|heropbouw|démolition|reconstruction)\w*\b).*\z/im,
        document_types: ['kb 20'], articles: %w[A-XXXVII] },
      { question: /\A(?=.*\b(?:btw|tva|vat|mehrwertsteuer)\b)(?=.*\b(?:restaurant|catering|horeca|maaltijd|repas)\w*\b).*\z/im,
        document_types: ['kb 20'], articles: %w[B-I] },
      { question: /\A(?=.*\b(?:btw|tva|vat|mehrwertsteuer)\b)(?=.*\b(?:voeding\w*|levensmiddel\w*|alimentation\w*|food)\b).*\z/im,
        document_types: ['kb 20'], articles: %w[1 A-X] },
      { question: /\A(?=.*\b(?:btw|tva|vat|mehrwertsteuer)\b)(?=.*(?:\b(?:tarief|taux|rate|steuersatz|percentage|procent)\w*\b|(?:0|6|12|21)\s*%)).*\z/im,
        document_types: ['kb 20'], articles: %w[1] },
      { question: /\bwerkelijke\s+beroepskosten\b|(?<!forfaitaire )\bberoepskosten\b|\bfrais\s+professionnels\b/i,
        document_types: ['wib 92'], articles: %w[49] },
      { question: /\b(?:kostenforfait|forfaitaire\s+beroepskosten|beroepskostenforfait|forfait\s+de\s+frais)\b/i,
        document_types: ['wib 92'], articles: %w[49 51] },
      { question: /\b(?:woon[-\s]?werkforfait|woon[-\s]?werkverkeer|trajet\s+domicile[-\s]travail)\b/i,
        document_types: ['wib 92'], articles: %w[66 66bis] },
      { question: /\b(?:huwelijksquoti[eë]nt|quotient\s+conjugal)\b/i,
        document_types: ['wib 92'], articles: %w[87 88] },
      { question: /\b(?:kinderen\s+ten\s+laste|enfants?\s+[àa]\s+charge|fiscale\s+voordelen?.{0,30}kinderen)\b/i,
        document_types: ['wib 92'], articles: %w[132 136] },
      { question: /\b(?:belastingschijven?|tarieven?\s+(?:in\s+de\s+)?personenbelasting|tranches?\s+d.imposition|barème\s+de\s+l.impôt|income\s+tax\s+brackets?|einkommensteuertarif(?:e|stufen)?)\b/i,
        document_types: ['wib 92'], articles: %w[130] },
      # Slash-numbered articles are stored INCONSISTENTLY by the scraper: most
      # keep the slash ('145/21', '145/33', '145/36') but some lost it, so
      # 145/1 is '1451', 145/8 is '1458' and 145/35 is '14535'. Those three pins
      # matched nothing at all until 2026-08-06 - verified by asking the DB for
      # the exact strings the pins used and getting zero rows, while the pin
      # regex matched the question perfectly. Pensioensparen and kinderopvang,
      # two of the most-asked personal-tax topics, silently had no pin.
      #
      # Only the CANONICAL spelling is configured. The collapsed twin is added at the SQL
      # boundary by article_number_spellings, so the pin list stays readable and citable.
      #
      # Blanket slash-stripping would indeed be unsafe: BTW '8/1' and '81' are different
      # articles and both exist (352 and 2,017 chars). But LENGTH separates the cases. A
      # bare all-digit number of four or more digits cannot be a real article number - no
      # Belgian tax code numbers run that high, and the fisconet API emits none across all
      # 4,255 documents - so it can only be a collapsed slash form. '8/1' collapses to '81',
      # two digits, and is therefore never treated as a collapse.
      { question: /\b(?:pensioensparen|pensionsparen|épargne[-\s]?pension|pension\s+savings?)\b/i,
        document_types: ['wib 92'], articles: %w[145/1 145/8] },
      { question: /\b(?:roerende\s+voorheffing|précompte\s+mobilier|kapitalertragsteuer|withholding\s+tax\s+on\s+(?:dividends?|interest))\b/i,
        document_types: ['wib 92'], articles: %w[269] },
      { question: COMPANY_CAR_TAX_PATTERN,
        document_types: ['wib 92', 'kb/wib 92'], articles: %w[36 18],
        targets: { 'wib 92' => %w[36], 'kb/wib 92' => %w[18] } },
      { question: Regexp.union(DIVERSE_INCOME_PATTERN, CRYPTO_TAX_PATTERN),
        document_types: ['wib 92'], articles: %w[90] },
      { question: /\b(?:huurinkomsten|onroerende\s+inkomsten?.{0,30}(?:huur|verhuur)|revenus?\s+immobiliers?.{0,30}(?:location|louer)|rental\s+income|mieteinnahmen)\b/i,
        document_types: ['wib 92'], articles: %w[7] },
      { question: /\b(?:belastingvermindering.{0,60}kinderopvang(?:kosten)?|kinderopvang(?:kosten)?.{0,60}(?:fiscaal|belasting|aftrek\w*)|aftrek\w*.{0,60}kinderopvang(?:kosten)?|frais\s+de\s+garde.{0,60}(?:réduction|impôt)|childcare.{0,60}(?:tax|deduct)|kinderbetreuungskosten.{0,60}steuer)\b/i,
        document_types: ['wib 92'], articles: %w[145/35] },
      { question: /\b(?:dubbele\s+belasting|double\s+imposition)\b.{0,60}\b(?:erfenis|nalatenschap|successie|succession)\b|\b(?:erfenis|nalatenschap|successie|succession)\b.{0,60}\b(?:buitenland|étranger|dubbele\s+belasting|double\s+imposition)\b/i,
        document_types: ['w.succ.'], articles: %w[17] },
      { question: /\b(?:erfbelasting(?:tarieven)?|successierecht(?:tarieven)?|droits?\s+de\s+succession)\b.{0,60}\b(?:brussel|bruxelles|walloni[eë]|waals|wallon)\b|\b(?:brussel|bruxelles|walloni[eë]|waals|wallon)\b.{0,60}\b(?:erfbelasting(?:tarieven)?|successierecht(?:tarieven)?|droits?\s+de\s+succession)\b/i,
        document_types: ['w.succ.'], articles: %w[48] }
    ].freeze

    STOP_WORDS = %w[
      de het een van in op voor met is dat dit die wat hoe wie waar moet mag kan
      wanneer waarom hoeveel welke welk zijn wordt worden bij als ik mijn rekenen
      le la les un une des du en est ce que qui pour avec dans dois puis je
      the a an of on for with that this what how must can i my
    ].to_set.freeze

    IMPORTANT_SHORT = %w[btw tva vat kb mb bw wib].freeze

    # Capture the complete identifier after an explicit article citation.
    # Belgian tax provisions commonly use slashes (145/33), dotted variants
    # (49.2bis) and annex rubrics (A-XXXI); truncating these to the first
    # integer silently retrieves a different rule.
    EXPLICIT_ARTICLE_PATTERN = /
      \bart(?:ikel|icle)?\.?\s*
      (?<number>
        [a-z]\s*-\s*[ivxlcdm]+(?:\s*(?:bis|ter))?
        |
        \d+(?:\s*(?:bis|ter|quater|quinquies|sexies|septies|octies|novies|decies)|[a-z])?
        (?:\s*[.\/]\s*\d+(?:\s*(?:bis|ter|quater|quinquies|sexies|septies|octies|novies|decies)|[a-z])?)*
      )
    /ixu

    # Only usable when tax_legislation actually carries lifecycle columns; the
    # taxonomy-walk corpus holds id, document_type, title_nl, title_fr and
    # nothing else. See legislation_current_sql.
    LEGISLATION_CURRENT_SQL = <<~SQL.squish.freeze
      CASE WHEN COALESCE(l.is_in_force, 1) <> 0
             AND COALESCE(l.is_abolished, 0) = 0
             AND (l.end_date IS NULL OR l.end_date = '' OR l.end_date >= DATE('now'))
           THEN 1 ELSE 0 END
    SQL

    # tax_legislation.title_nl/title_fr are NULL on every row of the walk
    # corpus; document_type ('WIB 92', 'BTW', 'W.Succ.', ...) is the only name
    # it stores, and it is the name the codes are actually cited by. Without
    # this fallback every tax fact reaches the model with a nil law title.
    LEGISLATION_TITLE_NL_SQL = "COALESCE(NULLIF(l.title_nl, ''), l.document_type)"
    LEGISLATION_TITLE_FR_SQL = "COALESCE(NULLIF(l.title_fr, ''), l.document_type)"

    # 57 of the corpus's 4,197 rows carry a slug instead of an article number
    # ('doc:w-btw-art-58-...', 'pdf:nl:packet:03'), and they are two different
    # things. Most are not law at all: 39 are "Bijwerking nr. 33 - te
    # vervangen pagina's" replacement-page notices and one is a 558k-char
    # whole-code dump - a VAT question retrieved one of these as its top fact,
    # cited under a broken #art_doc-w-btw-art-58sexies... anchor. The rest ARE
    # real articles whose number simply did not parse, holding text the corpus
    # has nowhere else (Btw KB nr. 59 art. 3), so excluding every slug row
    # would delete law.
    #
    # The title separates them: a real provision names its article, a
    # replacement-page notice or a whole-code dump never does. Applied through
    # real_law_only_sql, since article_title is itself a walk-schema column.
    NOT_A_SLUG_SQL = <<~SQL.squish.freeze
      COALESCE(a.article_number, '') NOT LIKE 'doc:%'
      AND COALESCE(a.article_number, '') NOT LIKE 'pdf:%'
    SQL

    # Four rows store an undecoded PDF container as their article text - the
    # KB/WIB 92 Annex III withholding-tax scales, whose article_number is
    # 'bijlage:III@...' so neither the slug rule above nor the site's pdf:*
    # exclusion catches them. Their text begins '%PDF-1.5 %...  98 0 obj'.
    # A row like this has no readable text in ANY language, so it can only
    # ever reach an answer as binary noise quoted as law.
    #
    # Anchored at the start deliberately: a law that merely mentions "PDF"
    # keeps its text. Decoding these properly needs PyMuPDF, which is not
    # installed on the host (the weekly sweep's parliamentary step already
    # fails on `No module named 'fitz'`), so until it is, the honest
    # behaviour is to serve nothing rather than a blob.
    NOT_PDF_BINARY_SQL = <<~SQL.squish.freeze
      substr(LTRIM(COALESCE(a.text_nl, '')), 1, 4) <> '%PDF'
      AND substr(LTRIM(COALESCE(a.text_fr, '')), 1, 4) <> '%PDF'
    SQL
    TITLE_NAMES_AN_ARTICLE_SQL = <<~SQL.squish.freeze
      LOWER(COALESCE(a.article_title, '')) LIKE '%art.%'
      OR LOWER(COALESCE(a.article_title, '')) LIKE '%artikel %'
      OR LOWER(COALESCE(a.article_title, '')) LIKE '%article %'
    SQL
    ARTICLE_CURRENT_SQL = <<~SQL.squish.freeze
      CASE WHEN COALESCE(a.is_abolished, 0) = 0
             AND (a.end_date IS NULL OR a.end_date = '' OR a.end_date >= DATE('now'))
           THEN 1 ELSE 0 END
    SQL

    # The three regions that took over succession and registration duties. All three must
    # be present before regional variants are surfaced instead of collapsed; see
    # select_per_article.
    DEVOLVED_REGIONS = %w[vlaams waals brussels].freeze

    def initialize(embedding_service:, language: 'nl')
      @language = language
      @language_id = %w[fr de].include?(language) ? 2 : 1
      @embedding_service = embedding_service
      @fisconet_db = nil
    end

    # Search FisconetPlus tax articles (WIB 92, BTW, W.Reg., W.Succ.).
    # Primary path: keyword search over tax_articles (3.6k rows, fast, and
    # immune to the nightly id-renumbering that broke the FAISS index).
    # question_embedding is only used when FISCONET_FAISS_ENABLED=true.
    # Returns array of article hashes with metadata (incl. legislation_id,
    # numac "FISCONET_<legislation_id>" and a working url).
    def search(question, question_embedding = nil, limit: 5)
      db = fisconet_db
      return [] unless db

      # Flemish inheritance tax is codified in the Vlaamse Codex Fiscaliteit,
      # not in the federal W.Succ. copy held by Fisconet.
      question_text = question.to_s
      return [] if question_text.match?(FLANDERS_PATTERN) && question_text.match?(INHERITANCE_TAX_PATTERN)

      pins = pinned_articles(db, question_text)
      results = pins + keyword_search(db, question_text, limit: [limit * 2, 8].max)
      results = results.uniq { |result| dedup_key(result) }

      # Optional FAISS supplement — only when explicitly re-enabled after the
      # index is rebuilt (see class comment).
      if FAISS_ENABLED && question_embedding.present? && results.size < limit
        extra = faiss_search(db, question_embedding, limit: limit - results.size)
        seen = results.to_set { |r| [r[:legislation_id], r[:article_number]] }
        extra.each { |r| results << r unless seen.include?([r[:legislation_id], r[:article_number]]) }
      end

      self.class.take_preserving_regional_groups(results, limit)
    rescue StandardError => e
      Rails.logger.error("[Fisconet] search failed: #{e.class}")
      []
    end

    # Working laws-page URL for a tax article. The fisconet pages are served
    # at /laws/FISCONET_<legislation_id> (uppercase prefix, LEGISLATION id —
    # NOT article id) and use canonical art_<article-number> anchors
    # (see _fisconet_show.html.erb). The old /laws/fisconet_<article_id>
    # format 404'd on every citation.
    def article_url(art)
      leg_id = art[:legislation_id]
      return nil if leg_id.blank?

      base = "/laws/FISCONET_#{leg_id}?language_id=#{@language_id}"
      # A slug row has no anchor on the page: the law page renders these rows
      # under the slug itself, so a derived #art_58sexies would either miss or,
      # worse, land on a different provision (the corpus holds "Btw, KB nr. 59,
      # Artikel 3", whose derived anchor is BTW's own article 3). Link the code,
      # not a fabricated anchor.
      return base if slug_number?(art[:article_number])

      fragment = normalize_article_number(art[:article_number])
      fragment.present? ? "#{base}#art_#{fragment}" : base
    end

    # The slug stays in the citation. Deriving a tidy number from it would read
    # "BTW art. 3" for the row titled "Btw, KB nr. 59 (2020), Artikel 3" - a
    # different instrument's article 3. An ugly citation is recoverable; a
    # confident wrong one is not.
    def slug_number?(number)
      number.to_s.start_with?('doc:', 'pdf:')
    end

    # Build context from fisconet tax articles
    def build_context(articles)
      parts = []
      label = @language == 'fr' ? 'FISCALITÉ' : 'FISCALITEIT'

      articles.each_with_index do |art, index|
        section = art[:section_path].present? ? " (#{art[:section_path]})" : ''
        link = art[:url] || article_url(art)
        # Name the region when the served text is a regional variant, so the model
        # cannot present one region's rule as the federal article. Federal and
        # jurisdiction-unstated texts read exactly as before.
        scope = region_label(art)
        scope_note = scope ? " [#{scope}]" : ''
        parts << "[Bron #{index + 1} - #{label}]\n#{art[:document_type]} - #{ensure_utf8(art[:legislation_title])}\nArtikel #{art[:article_number]}#{section}#{scope_note}#{"\nLINK: #{link}" if link}\n\n#{ensure_utf8(art[:text])}"
      end

      parts.join("\n\n---\n\n")
    end

    # Format fisconet sources for response cards
    def format_sources(articles)
      articles.map do |art|
        url = art[:url] || article_url(art)

        scope = region_label(art)

        source = {
          type: 'tax',
          document_type: art[:document_type],
          article_number: art[:article_number],
          article_title: art[:article_title] || "Art. #{art[:article_number]}",
          jurisdiction: art[:region],
          # Display-ready scope, kept as its OWN field rather than appended to
          # article_title. Appending was tried and was a silent no-op: the card
          # renderer rebuilds its label from a regex capture,
          # article_title.match(/Art\.?\s*(\d+\S*)/i) then uses artMatch[1], and \S*
          # stops at the first space - so "Art. 158ter (Vlaams Gewest)" rendered as
          # plain "Artikel 158ter" for every tax source, which is every source whose
          # title is the default "Art. N". The prompt context showed
          # "[Vlaams Gewest]" while the card beside it did not.
          jurisdiction_label: scope,
          title: art[:legislation_title],
          law_title: art[:legislation_title],
          section: art[:section_path],
          numac: art[:numac] || (art[:legislation_id] ? "FISCONET_#{art[:legislation_id]}" : nil),
          url: url,
          relevance: art[:similarity]&.round(3)
        }

        # Add article text excerpt (truncated to ~200 chars for display)
        if art[:text].present?
          clean_text = ensure_utf8(art[:text])
          excerpt = clean_text.gsub(/\s+/, ' ').strip[0..200]
          excerpt += '...' if clean_text.length > 200
          source[:excerpt] = excerpt
        end

        source
      end
    end

    # Detect if a question is tax-related
    def self.tax_question?(question)
      question_text = question.to_s
      q_down = question_text.downcase
      TAX_KEYWORDS.any? { |kw| q_down.include?(kw) } ||
        question_text.match?(COMPANY_CAR_TAX_PATTERN) ||
        question_text.match?(CRYPTO_TAX_PATTERN)
    end

    private

    def pinned_articles(db, question)
      hint = ARTICLE_HINTS.find { |candidate| question.match?(candidate[:question]) }
      return [] unless hint

      targets = hint[:targets] || hint[:document_types].to_h { |document_type| [document_type, hint[:articles]] }
      target_clauses = []
      params = []
      use_aliases = aliases_table?(db)
      targets.each do |document_type, articles|
        spellings = articles.flat_map { |article| article_number_spellings(article) }
        placeholders = (['?'] * spellings.length).join(', ')
        clause = "a.article_number IN (#{placeholders})"
        if use_aliases
          clause += ' OR a.id IN (SELECT article_id FROM tax_article_aliases ' \
                    "WHERE alias_number IN (#{placeholders}))"
        end
        target_clauses << "(LOWER(l.document_type) = ? AND (#{clause}))"
        params << document_type.downcase
        params.concat(spellings)
        params.concat(spellings) if use_aliases
      end

      preferred_text = @language == 'fr' ? 'a.text_fr' : 'a.text_nl'
      fallback_text = @language == 'fr' ? 'a.text_nl' : 'a.text_fr'
      rows = db.execute(
        "SELECT a.id, a.legislation_id, a.article_number, a.text_nl, a.text_fr, #{section_path_sql(db)},
                #{LEGISLATION_TITLE_NL_SQL}, #{LEGISLATION_TITLE_FR_SQL}, l.document_type, #{fisconet_id_sql(db)}
                #{region_select(db)}
         FROM tax_articles a
         JOIN tax_legislation l ON a.legislation_id = l.id
         WHERE (#{target_clauses.join(' OR ')})
           AND TRIM(COALESCE(NULLIF(#{preferred_text}, ''), #{fallback_text}, '')) <> ''
         ORDER BY #{legislation_current_sql(db)} DESC,
                  #{ARTICLE_CURRENT_SQL} DESC,
                  #{region_order_sql(db)}
                  LENGTH(COALESCE(NULLIF(#{preferred_text}, ''), #{fallback_text}, '')) DESC,
                  #{legislation_updated_order_sql(db)}l.id DESC, a.id DESC",
        params
      )

      # Every accepted spelling maps back to the canonical one, so a row stored as '1458' is
      # cited as '145/8' and still sorts into the pin order.
      canonical = {}
      hint[:articles].each do |article|
        article_number_spellings(article).each { |sp| canonical[sp.downcase] = article }
      end

      indexed = rows.each_with_index.map do |row, index|
        article = row_to_article(row, @language == 'fr')
        article[:article_number] =
          canonical.fetch(article[:article_number].to_s.downcase, article[:article_number])
        [article, index]
      end

      # Within one article, prefer the row that is NOT an index page. Comparing two rows of
      # the SAME article is the one place a heading count is trustworthy: WIB 92 145/8 stores
      # 37,114 chars holding many articles while its '1458' twin holds the real 3,183-char
      # article. An absolute size threshold has failed repeatedly; this relative comparison
      # only ever chooses between two spellings of one provision. The SQL order, which puts
      # current legislation and fuller text first, breaks ties.
      article_order = hint[:articles].each_with_index.to_h
      indexed.group_by { |article, _| dedup_key(article, scope_by: :document_type) }
             .map { |_, group| group.min_by { |article, index| [heading_count(article[:text]), index] }.first }
             .sort_by { |article| article_order.fetch(article[:article_number].to_s, hint[:articles].length) }
             .map { |article| article.merge(similarity: 99.0, pinned: true) }
    end

    # Distinct "Art. N" headings inside one article's text. High means the row is an index
    # page rather than a single provision.
    def heading_count(text)
      text.to_s.scan(/\bart(?:ikel|icle)?\.?\s*\d+/i)
          .map { |heading| heading.downcase.delete(' ') }.uniq.length
    end

    # The stored spelling may have lost its slash, so ask for both forms. Restricted to bare
    # forms of four or more digits, or asking for BTW '8/1' would also return the unrelated
    # article 81.
    def article_number_spellings(number)
      text = number.to_s
      bare = text.delete('/')
      bare != text && bare.match?(/\A\d{4,}\z/) ? [text, bare] : [text]
    end

    # Keyword retrieval over tax_articles. 3,602 rows — a filtered LIKE scan
    # is fast and needs no index that the nightly scrape could invalidate.
    def keyword_search(db, question, limit: 5)
      q_down = question.downcase
      explicit_art = extract_explicit_article_number(question)
      keywords = extract_tax_keywords(q_down)
      return [] if keywords.empty? && explicit_art.blank?

      is_french = @language == 'fr'
      text_col = is_french ? "COALESCE(NULLIF(a.text_fr,''), a.text_nl)" : "COALESCE(NULLIF(a.text_nl,''), a.text_fr)"

      where = []
      params = []

      # Steer to the right tax code when the question names one (a VAT
      # question must not answer from registration-duties articles).
      hint = CODE_HINTS.find { |h| q_down.match?(h[:question]) }
      if hint
        leg_like = hint[:legislation].map { '(l.document_type LIKE ? OR l.title_nl LIKE ? OR l.title_fr LIKE ?)' }.join(' OR ')
        where << "(#{leg_like})"
        hint[:legislation].each { |p| params.push(p, p, p) }
      end

      retrieval_clauses = []
      if keywords.any?
        retrieval_clauses << keywords.map { "#{text_col} LIKE ?" }.join(' OR ')
        keywords.each { |k| params << "%#{k}%" }
      end
      if explicit_art
        # Both spellings, for the same reason as the pins: the stored number may have lost its
        # slash. And an alias lookup, because a repeal run is the ONLY source for the articles
        # it names - art. 430 has no row of its own, and its alias points at the 425-432
        # repeal notice, which is the correct answer to "what does art. 430 say".
        spellings = article_number_spellings(explicit_art)
        marks = (['LOWER(?)'] * spellings.length).join(', ')
        clause = "LOWER(a.article_number) IN (#{marks})"
        params.concat(spellings)
        if aliases_table?(db)
          clause += ' OR a.id IN (SELECT article_id FROM tax_article_aliases ' \
                    "WHERE LOWER(alias_number) IN (#{marks}))"
          params.concat(spellings)
        end
        retrieval_clauses << "(#{clause})"
      end
      where << "(#{retrieval_clauses.join(' OR ')})"
      where << real_law_only_sql(db)

      rows = db.execute(
        "SELECT a.id, a.legislation_id, a.article_number, a.text_nl, a.text_fr, #{section_path_sql(db)},
                #{LEGISLATION_TITLE_NL_SQL}, #{LEGISLATION_TITLE_FR_SQL}, l.document_type, #{fisconet_id_sql(db)},
                #{legislation_current_sql(db)} AS legislation_current,
                #{ARTICLE_CURRENT_SQL} AS article_current
                #{region_select(db)}
         FROM tax_articles a
         JOIN tax_legislation l ON a.legislation_id = l.id
         WHERE #{where.join(' AND ')}
         ORDER BY legislation_current DESC, article_current DESC,
                  #{legislation_updated_order_sql(db)}l.id DESC, a.id DESC
         LIMIT 400", params
      )

      scored = rows.map do |row|
        art = row_to_article(row, is_french)
        art[:similarity] = score_article(art, keywords, explicit_art)
        { article: art, integrity: [row[10].to_i, row[11].to_i] }
      end

      select_per_article(scored, limit: limit)
    end

    # Collapse candidates to what the chatbot should quote. Extracted from
    # keyword_search so it can be unit tested without a database: the previous inline
    # version could only be exercised end to end, and duplicated selection logic is what
    # made an earlier blob-repair bug unresolvable.
    #
    # The scraper occasionally holds duplicate scrapes of the same code (e.g. two WIB 92
    # legislations), so candidates are grouped on (code, article number) and the best row
    # wins. Highest tuple wins: currency of the law and article first, then jurisdiction,
    # then score, then fullness.
    #
    # Jurisdiction sits ABOVE score on purpose. Where only one region is present these are
    # alternative texts of the SAME article and citing a region's rule as "the article" is
    # a worse error than citing slightly lower-scored federal text. Before that, the chain
    # fell through to "fullest row wins" and a verbose Flemish body could displace the
    # federal article.
    #
    # BUT when a group holds ALL THREE devolved regions, every variant is kept instead.
    # For W.Succ. and W.Reg. the region sets the rate, the taxable base and the exemptions
    # (art. 3, 4° and art. 4, § 1 Bijzondere wet 16.01.1989, NUMAC 1989021010), so
    # collapsing to federal would quote a rate that does not apply. Owner decision
    # 2026-08-07: surface all applicable variants and let the answer state the difference.
    #
    # The gate requires all THREE, not merely two distinct values, because an incomplete
    # set is the failure mode this is meant to prevent: quoting the Flemish and Walloon
    # rates while silently omitting Brussels invites an answer that is wrong for Brussels.
    # Federal may or may not be present alongside them.
    #
    # That gate is also what makes this safe to ship BEFORE the regional ingest lands.
    # Production holds one variant for nearly every article today, plus a stray region for
    # a few dozen, so no group trips it and existing answers are unchanged; once
    # fisconet_ingest_walk.py fills in the full set they surface automatically.
    def select_per_article(scored, limit:)
      rank_key = lambda do |candidate|
        art = candidate[:article]
        [candidate[:integrity], region_rank(art[:region]),
         art[:similarity].to_f, art[:text].to_s.length]
      end

      groups = scored.group_by do |candidate|
        art = candidate[:article]
        [art[:document_type].to_s.downcase, art[:article_number].to_s.downcase]
      end

      selected = groups.map do |_key, candidates|
        regions = candidates.map { |c| c[:article][:region].to_s }.uniq
        if (DEVOLVED_REGIONS - regions).empty?
          best_per_region(candidates, rank_key)
        else
          [candidates.max_by { |candidate| rank_key.call(candidate) }[:article]]
        end
      end

      # Emit WHOLE groups. A partial regional set is worse than none: showing the Flemish
      # and Walloon rates but not the Brussels one invites an answer that is wrong for
      # Brussels, which is the very failure this exists to prevent.
      ordered = selected.sort_by do |arts|
        [-arts.map { |art| art[:similarity].to_f }.max,
         -arts.map { |art| art[:text].to_s.length }.max]
      end

      kept = []
      ordered.each do |arts|
        break if kept.length >= limit
        # Never split a group. A single regional set is allowed to overshoot `limit`
        # rather than be emitted partially; the owner accepted that cost explicitly.
        break if kept.any? && kept.length + arts.length > limit

        kept.concat(arts)
      end
      kept
    end

    def best_per_region(candidates, rank_key)
      per_region = {}
      candidates.each do |candidate|
        region = candidate[:article][:region].to_s
        cur = per_region[region]
        better = cur.nil? || (rank_key.call(candidate) <=> rank_key.call(cur)).positive?
        per_region[region] = candidate if better
      end
      per_region.values.map { |candidate| candidate[:article] }
    end

    # Truncate WITHOUT splitting a complete regional set.
    #
    # select_per_article goes to some trouble to emit whole groups, and then every later
    # truncation quietly undoes it: `results.first(limit)` at the end of #search, and
    # `tax_articles.take(context_policy.fetch(:fisconet))` in the orchestrator, where the
    # bound is 3 on every bounded tier while a complete set is 4 or 5 rows.
    #
    # A partial set is worse than none: showing the Flemish and Walloon rates while
    # silently dropping Brussels invites an answer that is wrong for Brussels, which is the
    # very failure the grouping exists to prevent. This is the same bug the orchestrator
    # already records for regional_docs - "keeping only the first result here silently
    # undid that safety contract and made the low tier answer from an arbitrary single
    # region" - arriving a second time by a different route.
    #
    # Latent while production holds one variant per article; live the moment the regional
    # ingest lands.
    def self.take_preserving_regional_groups(articles, limit)
      articles = Array(articles)
      limit = limit.to_i
      return [] if limit <= 0 # first(-1) raises; a non-positive budget keeps nothing

      kept = []
      regional_units(articles).each do |unit|
        break if kept.length >= limit
        # A single regional set may overshoot `limit` rather than be emitted partially;
        # the owner accepted that cost explicitly.
        break if kept.any? && kept.length + unit.length > limit

        kept.concat(unit)
      end
      kept
    end

    # Articles in reading order, with the members of a COMPLETE regional set collected into
    # one indivisible unit at the position of its first member. Everything else is a unit of
    # one. The completeness test is the same predicate select_per_article uses, deliberately:
    # a hard-coded list of regionalised codes would be a second source of truth to drift.
    def self.regional_units(articles)
      grouped = articles.group_by { |art| variant_group_key(art) }
      complete = grouped.each_key.select do |key|
        (DEVOLVED_REGIONS - grouped[key].map { |art| art[:region].to_s }.uniq).empty?
      end.to_set

      units = []
      position = {}
      articles.each do |art|
        key = variant_group_key(art)
        if !complete.include?(key)
          units << [art]
        elsif position.key?(key)
          units[position[key]] << art
        else
          position[key] = units.length
          units << [art]
        end
      end
      units
    end

    def self.variant_group_key(article)
      [article[:document_type].to_s.downcase, article[:article_number].to_s.downcase]
    end

    def extract_explicit_article_number(question)
      match = EXPLICIT_ARTICLE_PATTERN.match(question.to_s)
      return nil unless match

      match[:number].gsub(/\s+/, '')
    end

    def extract_tax_keywords(q_down)
      words = q_down.scan(/[[:alnum:]]+/)
      words.select { |w| (w.length >= 4 || IMPORTANT_SHORT.include?(w)) && !STOP_WORDS.include?(w) }
           .uniq.first(8)
    end

    def score_article(art, keywords, explicit_art)
      text_down = art[:text].to_s.downcase
      head = text_down[0, 400]
      score = 0.0
      distinct = 0
      keywords.each do |kw|
        occ = text_down.scan(kw).size
        next if occ.zero?

        distinct += 1
        score += [occ, 4].min
        score += 2 if head.include?(kw)
        score += 2 if art[:section_path].to_s.downcase.include?(kw)
      end
      score += distinct * 3
      score += 12 if explicit_art && art[:article_number].to_s.casecmp?(explicit_art)
      score
    end

    # Jurisdiction of the text being served, for display and for ranking.
    #
    # Registration and succession duties are regionalised, and parts of WIB 92 are
    # too, so the corpus deliberately carries a region's text where that is the only
    # version published. Retrieval must prefer the federal article and must never
    # present a single region's rule as the federal one.
    REGION_LABELS = {
      'vlaams' => 'Vlaams Gewest',
      'waals' => 'Waals Gewest',
      'brussels' => 'Brussels Hoofdstedelijk Gewest'
    }.freeze

    REGION_LABELS_FR = {
      'vlaams' => 'Région flamande',
      'waals' => 'Région wallonne',
      'brussels' => 'Région de Bruxelles-Capitale'
    }.freeze

    def self.region_label_for(region, language:)
      (language.to_s == 'fr' ? REGION_LABELS_FR : REGION_LABELS)[region.to_s]
    end

    # The label the MODEL sees, which is not the same job as the label on a source card.
    # Federal is named here because the context is the one place four near-identical blocks
    # have to be told apart, and because best_per_region emits one row per distinct region
    # string with no filtering, so a fired group can hold federal alongside the three
    # regions. On a card it stays unlabelled: printing "(Federaal)" on the many W.Succ. and
    # W.Reg. cards that read fine today would be noise.
    #
    # A blank region stays unlabelled in both. NULL is not federal.
    def self.context_region_label(region, language:)
      if region.to_s == 'federal'
        return language.to_s == 'fr' ? 'texte fédéral' : 'federale tekst'
      end

      region_label_for(region, language: language)
    end

    # Higher sorts first. Federal beats an unstated jurisdiction, which beats any
    # single region's text.
    def region_rank(region)
      case region.to_s
      when 'federal' then 2
      when 'vlaams', 'waals', 'brussels' then 0
      else 1
      end
    end

    # Card label. Was Dutch-only, so a French answer carried "Vlaams Gewest" on its
    # source cards.
    def region_label(art)
      self.class.region_label_for(art[:region], language: @language)
    end

    # Probed rather than assumed, and memoized. The scraper adds region_nl/region_fr
    # through its self-migrating ALTER list, so a database predating that migration
    # is a legitimate state, and naming a missing column would raise inside the
    # retrieval path.
    def region_columns?(db)
      return @region_columns unless @region_columns.nil?

      cols = db.execute('PRAGMA table_info(tax_articles)').map { |row| row[1] }
      @region_columns = cols.include?('region_nl') && cols.include?('region_fr')
    rescue StandardError
      @region_columns = false
    end

    # Probed and memoized for the same reason as region_columns?. The
    # taxonomy-walk switchover (2026-08-08) dropped fisconet_id, is_in_force,
    # is_abolished, end_date and updated_at from tax_legislation and
    # section_path from tax_articles. Naming any of them against the walk
    # corpus raises "no such column" inside the retrieval path, which the
    # rescue turns into zero tax facts - so each one is selected only when the
    # database in hand actually has it.
    def columns_of(db, table)
      @columns_of ||= {}
      @columns_of[table] ||= db.execute("PRAGMA table_info(#{table})").map { |row| row[1] }
    rescue StandardError
      @columns_of[table] = []
    end

    def legislation_column?(db, name)
      columns_of(db, 'tax_legislation').include?(name)
    end

    # Ranks in-force legislation above repealed. The walk corpus stores one row
    # per code and all five are in force, so there is nothing to rank there and
    # the tier collapses to a constant.
    def legislation_current_sql(db)
      return '1' unless %w[is_in_force is_abolished end_date].all? { |c| legislation_column?(db, c) }

      LEGISLATION_CURRENT_SQL
    end

    # article_title is not a section path substitute: it holds a synthesized
    # label ('Artikel 1, WIB 92 (inkomsten 2026)'), so scoring against it would
    # award every WIB 92 article points for the word "inkomsten". The region a
    # row belongs to already reaches the prompt via region_nl/region_fr.
    def section_path_sql(db)
      columns_of(db, 'tax_articles').include?('section_path') ? 'a.section_path' : 'NULL AS section_path'
    end

    # Keeps replacement-page notices and whole-code dumps out of the answer.
    # Without article_title there is no way to tell a slug row that is a real
    # article from one that is chrome, so such a corpus keeps every row rather
    # than risk dropping law.
    def real_law_only_sql(db)
      slug_rule =
        if columns_of(db, 'tax_articles').include?('article_title')
          "(#{NOT_A_SLUG_SQL} OR #{TITLE_NAMES_AN_ARTICLE_SQL})"
        else
          "(#{NOT_A_SLUG_SQL})"
        end
      "#{slug_rule} AND (#{NOT_PDF_BINARY_SQL})"
    end

    def fisconet_id_sql(db)
      legislation_column?(db, 'fisconet_id') ? 'l.fisconet_id' : 'NULL AS fisconet_id'
    end

    # Trailing comma included so the caller can drop the whole tier cleanly.
    def legislation_updated_order_sql(db)
      legislation_column?(db, 'updated_at') ? "COALESCE(l.updated_at, '') DESC, " : ''
    end

    # Probed and memoized, for the same reason as region_columns?. tax_article_aliases arrives
    # with the taxonomy-driven ingest, so a database predating it is a legitimate state and
    # naming a missing table would raise inside the retrieval path.
    def aliases_table?(db)
      return @aliases_table unless @aliases_table.nil?

      @aliases_table = db.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'tax_article_aliases'"
      ).any?
    rescue StandardError
      @aliases_table = false
    end

    # Always the LAST two selected columns, so existing positional indices in the
    # callers (row[10], row[11]) keep working and row_to_article can read these from
    # the end regardless of how many columns a given query selects.
    def region_select(db)
      region_columns?(db) ? ', a.region_nl, a.region_fr' : ', NULL, NULL'
    end

    def region_order_sql(db)
      return '' unless region_columns?(db)

      "CASE WHEN COALESCE(a.region_nl, '') IN ('vlaams', 'waals', 'brussels') " \
        "OR COALESCE(a.region_fr, '') IN ('vlaams', 'waals', 'brussels') " \
        'THEN 1 ELSE 0 END ASC, '
    end

    # Dedup key that collapses the SAME article written two ways, without merging two
    # genuinely different articles.
    #
    # The corpus stores some sub-articles both ways: "145/1" from the API path and
    # "1451" from the PDF path, which collapses the superscript in 145<sup>1</sup>.
    # The pins deliberately list both spellings, so a pinned lookup can return one
    # provision twice with identical text - halving the 4-5 source budget and
    # inviting the model to treat "Art. 1451" and "Art. 145/1" as distinct rules.
    #
    # Comparing slash-stripped numbers ALONE would be wrong and dangerous: '8/1' and
    # '81' are different BTW articles, '212' and '21/2' are both real in W.Reg., and
    # '71' and '7/1' are both real in W.Succ. So the key requires slash-insensitivity
    # AND identical text. Same article written two ways has identical text and
    # collapses; different articles that merely look alike have different text and
    # both survive.
    # Two spellings of ONE article must share a key; two DIFFERENT articles must not. See
    # article_number_spellings for why length is the safe discriminator: '145/1' and '1451'
    # are the same provision, while BTW '8/1' and '81' are not.
    def dedup_number(number)
      text = number.to_s.downcase
      bare = text.delete('/')
      bare.match?(/\A\d{4,}\z/) ? bare : text
    end

    # REGION is the discriminator here, not text. Keying on text meant every duplicate scrape
    # of an article survived as though the duplicates were different provisions, and both
    # spellings of 145/1 were returned twice over. Region is what genuinely distinguishes the
    # four W.Succ. variants of one article number, so it keeps those apart while collapsing
    # the duplicates.
    def dedup_key(article, scope_by: :legislation_id)
      [article[scope_by].to_s.downcase,
       dedup_number(article[:article_number]),
       article[:region].to_s]
    end

    def row_to_article(row, is_french)
      article_id, leg_id, art_num, text_nl, text_fr, section_path, title_nl, title_fr, doc_type, fisconet_id = row
      region_nl, region_fr = row[-2], row[-1]
      text = is_french ? (text_fr.presence || text_nl) : (text_nl.presence || text_fr)
      title = is_french ? (title_fr.presence || title_nl) : (title_nl.presence || title_fr)
      # Cut the not-yet-in-force block off BEFORE the 3000-char slice below. tax_articles
      # has no variant column, so a marker in the body is the only signal there has ever
      # been that a row carries future law - and slicing first can delete the marker while
      # keeping the text it introduced, which is the one outcome worse than doing nothing.
      # This runs ahead of scoring, dedup and select_per_article, so nothing downstream
      # ever ranks a row on words that are not in force.
      in_force, future_block = LegalChatbot::FutureLaw.split(text.to_s)
      art = {
        region: (is_french ? region_fr : region_nl).presence,
        article_id: article_id,
        legislation_id: leg_id,
        article_number: art_num,
        article_title: "Art. #{art_num}",
        text: in_force.to_s[0..3000],
        future_amendment: !future_block.nil?,
        future_effective_date: future_block && LegalChatbot::FutureLaw.effective_date(future_block),
        section_path: section_path,
        legislation_title: title,
        law_title: title,
        document_type: doc_type,
        fisconet_id: fisconet_id,
        numac: leg_id ? "FISCONET_#{leg_id}" : nil,
        similarity: 0.0
      }
      art[:url] = article_url(art)
      art
    end

    # Legacy FAISS path — see class comment for why this is off by default.
    def faiss_search(db, question_embedding, limit: 5)
      require 'net/http'
      require 'json'

      uri = URI("#{FAISS_URL}/search")
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      request.body = { embedding: question_embedding, limit: limit }.to_json

      response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 10, open_timeout: 5) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("[Fisconet FAISS] HTTP error: #{response.code}")
        return []
      end

      faiss_results = JSON.parse(response.body)['results'] || []
      return [] if faiss_results.empty?

      article_ids = faiss_results.map { |r| r['article_id'] }
      similarity_map = faiss_results.to_h { |r| [r['article_id'], r['similarity']] }

      placeholders = article_ids.map { '?' }.join(',')
      rows = db.execute(
        "SELECT a.id, a.legislation_id, a.article_number, a.text_nl, a.text_fr, #{section_path_sql(db)},
                #{LEGISLATION_TITLE_NL_SQL}, #{LEGISLATION_TITLE_FR_SQL}, l.document_type, #{fisconet_id_sql(db)}
                #{region_select(db)}
         FROM tax_articles a
         JOIN tax_legislation l ON a.legislation_id = l.id
         WHERE a.id IN (#{placeholders})", article_ids
      )

      is_french = @language == 'fr'
      rows.map do |row|
        art = row_to_article(row, is_french)
        art[:similarity] = similarity_map[art[:article_id]] || 0.0
        art
      end.sort_by { |m| -m[:similarity] }
    rescue StandardError => e
      Rails.logger.error("[Fisconet] FAISS search failed: #{e.class}")
      []
    end

    # Lazy-initialize connection to FisconetPlus SQLite DB
    def fisconet_db
      @fisconet_db ||= SQLite3::Database.new(FISCONET_DB)
    rescue SQLite3::CantOpenException
      Rails.logger.warn("FisconetPlus DB not available at #{FISCONET_DB}")
      nil
    end
  end
end
