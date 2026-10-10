# frozen_string_literal: true

# == FisconetSearchService
#
# Service for searching tax legislation articles from the FisconetPlus database.
# Returns one result per matching legislation/language, like the Justel rows.
# Title/code searches never implicitly search the tax articles' body text.
#
# Numac convention: "FISCONET_<legislation_id>" (e.g. FISCONET_1, FISCONET_2)
#
# === Database schemas (for reference):
#
# tax_legislation:
#   id, fisconet_id, numac, document_number, title_nl, title_fr, title_de,
#   document_type, category, subcategory, publication_date, effective_date, end_date,
#   is_consolidated, is_in_force, preamble_nl, preamble_fr, source_url,
#   last_modified, created_at, updated_at
#
# tax_articles:
#   id, legislation_id, article_number, article_title, text_nl, text_fr, text_de,
#   parent_article_id, section_path, display_order, version_date, end_date,
#   modified_by, modification_notes, created_at, updated_at
#
class FisconetSearchService
  # Wrapper class that duck-types with Legislation for unified display in search results.
  # Does NOT respond to fisconet? - so _law.html.erb renders a normal Details link.
  class FisconetResult
    attr_reader :id, :numac, :title, :date, :language_id, :law_type_id,
                :is_abolished, :is_empty_content, :tags, :justel, :reflex,
                :document_type, :source_url

    def initialize(attrs)
      @id = attrs[:id]
      @numac = attrs[:numac]
      @title = attrs[:title]
      @date = attrs[:date]
      @language_id = attrs[:language_id] || 1
      @law_type_id = 2 # Treat as "Wet"
      @is_abolished = ![true, 1].include?(attrs[:is_in_force])
      @is_empty_content = false
      @tags = nil
      @justel = 'N/A'
      @reflex = 'N/A'
      @document_type = attrs[:document_type] || 'WIB 92'
      @source_url = attrs[:source_url]
    end

    # Rails route helpers call to_param to generate the URL parameter
    def to_param
      @numac
    end
  end

  FISCONET_DB_PATH = ENV.fetch('FISCONET_DB',
                               '/mnt/HC_Volume_104299669/embeddings/fisconet.sqlite3')

  # Numac prefix for all Fisconet legislation
  FISCONET_PREFIX = 'FISCONET_'

  # Known publication dates for major Belgian tax codes (fallback when DB field is empty)
  KNOWN_TAX_DATES = {
    'WIB 92' => Date.new(1992, 4, 10),
    'KB/WIB 92' => Date.new(1993, 8, 27),
    'BTW' => Date.new(1969, 7, 3),
    'W.Reg.' => Date.new(1939, 11, 30),
    'W.Succ.' => Date.new(1936, 3, 31),
    'Succ.' => Date.new(1936, 3, 31),
    'W.Div.' => Date.new(1927, 12, 28)
  }.freeze

  # The real Justel numac of each tax code, so the law page can link the
  # Justel entry ("numac_real"). The taxonomy-walk corpus stores no numac
  # column - the old scraper's was populated per legislation - and these five
  # codes are a closed set, verified against laws.prod on 2026-08-09 (the
  # KB/WIB 92 candidate with 872 articles, not the 18-article duplicate).
  REAL_NUMACS = {
    'WIB 92' => '1992041050',
    'KB/WIB 92' => '1993082751',
    'BTW' => '1969070305',
    'W.Succ.' => '1936033102',
    'W.Reg.' => '1939113002'
  }.freeze

  # Check whether a numac belongs to Fisconet
  def self.fisconet_numac?(numac)
    numac.to_s.start_with?(FISCONET_PREFIX)
  end

  # Extract legislation_id from a Fisconet numac  ("FISCONET_1" → 1)
  def self.legislation_id_from_numac(numac)
    numac.to_s.delete_prefix(FISCONET_PREFIX).to_i
  end

  # Build the canonical numac for a legislation row
  def self.numac_for(legislation_id)
    "#{FISCONET_PREFIX}#{legislation_id}"
  end

  # Current numac of each tax code, keyed by document_type ('WIB 92', 'BTW',
  # 'W.Reg.', ...). Never pin a legislation id in a view: ids drift on every
  # corpus merge, and the homepage that pinned FISCONET_4 and FISCONET_5 had
  # the registration and succession codes swapped once the table moved under
  # it. Returns {} when the corpus is unavailable, so callers can render a
  # label with no link rather than a link to nowhere.
  #
  # Memoised under the corpus file's mtime, so the map and the homepage
  # fragment (which is keyed on the same stamp) move together: a fixed key
  # would let a fresh fragment bake the pre-swap map for a day. An empty
  # result (locked or missing file) is never memoised. On a duplicate
  # document_type the row with the most articles wins.
  def self.numacs_by_document_type
    stamp = begin
      File.mtime(FISCONET_DB_PATH).to_i
    rescue SystemCallError
      0
    end
    Rails.cache.fetch("fisconet/numacs_by_document_type/v2/#{stamp}", expires_in: 1.hour, skip_nil: true) do
      rows = all_legislations
      next nil if rows.empty?

      rows.sort_by { |row| row[:article_count].to_i }
          .to_h { |row| [row[:document_type].to_s, numac_for(row[:id])] }
    end || {}
  end

  # The reverse of REAL_NUMACS: given the Justel numac of a tax code, the
  # current Fisconet numac for the same code, or nil when there is none.
  #
  # The Fisconet page has always linked back to Justel; this is the link the
  # other way. It matters most where the two sources diverge: ejustice has
  # been serving an EMPTY text section for the BTW Wetboek (checked
  # 2026-09-04, both languages), so the Justel page shows a July
  # consolidation while Fisconet carries text refreshed daily. The two lanes
  # stay separate by design - this only lets a reader cross between them.
  #
  # Resolved through numacs_by_document_type rather than a pinned id, for the
  # reason documented there: ids drift on every corpus merge.
  def self.fisconet_numac_for_justel(numac)
    document_type = REAL_NUMACS.key(numac.to_s)
    return nil if document_type.nil?

    numacs_by_document_type[document_type]
  end

  # Safe date parser – returns nil instead of raising
  def self.parse_date_safe(val)
    return nil if val.blank?

    Date.parse(val.to_s)
  rescue StandardError => e
    Rails.logger.warn("[FisconetSearch] Operation failed: #{e.message}")
    nil
  end

  # ─── Search ────────────────────────────────────────────────────────────
  # Returns one FisconetResult per matching legislation/language. Fisconet has
  # no tags column; a tags-only search must not silently become a body search.
  #
  # @param params [Hash] Search parameters (:title, :lang_nl, :lang_fr,
  #   :search_in_title, :search_in_tags, :search_in_text)
  # @return [Array<FisconetResult>]
  def self.search(params)
    return [] unless File.exist?(FISCONET_DB_PATH)

    params = params.to_h.with_indifferent_access
    title = params[:title].to_s.strip
    return [] if title.blank?

    language_filters = %i[lang_nl lang_fr lang_de].any? { |key| params[key].present? }
    languages = if language_filters
                  { nl: 1, fr: 2 }.select { |language, _| params["lang_#{language}"] == '1' }
                else
                  { nl: 1 }
                end
    return [] if languages.empty?

    search_title = params[:search_in_title] != '0'
    search_text = params[:search_in_text] == '1'
    return [] unless search_title || search_text

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      search_term = "%#{ActiveRecord::Base.sanitize_sql_like(title.downcase)}%"

      # Query each selected source language separately. A French-only body hit
      # must not produce a Dutch row (nor vice versa); selecting both languages
      # may produce the two distinct language versions of the same code.
      languages.flat_map do |language, lang_id|
        predicates = []
        binds = []
        if search_title
          # In the walk corpus title_nl/title_fr may be NULL. document_type is
          # the code's actual displayed title in that case, not article text.
          predicates << "(LOWER(l.title_#{language}) LIKE ? ESCAPE '\\' OR LOWER(l.document_type) LIKE ? ESCAPE '\\')"
          binds.push(search_term, search_term)
          if language == :fr
            predicates << "(l.document_type = 'WIB 92' AND LOWER('CIR 92') LIKE ? ESCAPE '\\')"
            binds << search_term
          end
        end
        if search_text
          predicates << <<~SQL.squish
            EXISTS (SELECT 1 FROM tax_articles a WHERE a.legislation_id = l.id
              AND NULLIF(TRIM(a.text_#{language}), '') IS NOT NULL
              AND (LOWER(a.article_number) LIKE ? ESCAPE '\\'
                OR LOWER(a.text_#{language}) LIKE ? ESCAPE '\\'))
          SQL
          binds.push(search_term, search_term)
        end

        rows = db.execute(<<~SQL, binds)
          SELECT l.id, l.title_nl, l.title_fr, l.document_type
          FROM tax_legislation l
          WHERE #{predicates.join(' OR ')}
          ORDER BY l.id
        SQL

        rows.map do |row|
          doc_type = row['document_type'] || 'WIB 92'
          display_code = lang_id == 2 && doc_type == 'WIB 92' ? 'CIR 92' : doc_type

          # A missing source-language title falls back to the code, never to a
          # title in an unchecked language. The walk corpus may carry no titles.
          display_title = row["title_#{language}"].presence || display_code

          FisconetResult.new(
            id: row['id'],
            numac: numac_for(row['id']),
            title: display_title,
            date: KNOWN_TAX_DATES[doc_type],
            document_type: display_code,
            language_id: lang_id,
            source_url: nil,
            is_in_force: true
          )
        end
      end
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] Database error: #{e.message}")
      []
    ensure
      db&.close
    end
  end

  # ─── Legislation info ──────────────────────────────────────────────────
  # Returns a single legislation metadata hash from tax_legislation.
  #
  # @param legislation_id [Integer]
  # @return [Hash, nil]
  def self.legislation_info(legislation_id)
    return nil unless File.exist?(FISCONET_DB_PATH)

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      # Walk-corpus schema: only id/document_type/title_nl/title_fr exist.
      # Everything the old scraper stored per legislation is synthesized: the
      # real Justel numac from REAL_NUMACS (a closed set of five codes), the
      # publication date from KNOWN_TAX_DATES, and the flags from what is
      # always true of a consolidated current code. Fields with no walk
      # equivalent are nil, and the views are nil-tolerant on all of them.
      row = db.get_first_row(<<~SQL, [legislation_id])
        SELECT l.id, l.title_nl, l.title_fr, l.document_type,
               (SELECT COUNT(*) FROM tax_articles WHERE legislation_id = l.id) AS article_count
        FROM tax_legislation l
        WHERE l.id = ?
      SQL

      edition = edition_of(db, legislation_id)
      db.close
      return nil unless row

      doc_type = row['document_type']
      # The code this row is an edition of. 'WIB 92 (inkomsten 2027)' is still WIB 92, so
      # it keeps the Justel cross-link and the code's dates.
      code = edition[:base_code].presence || doc_type
      {
        id: row['id'],
        fisconet_id: nil,
        numac_real: REAL_NUMACS[doc_type] || REAL_NUMACS[code],
        document_number: nil,
        title_nl: row['title_nl'].presence || doc_type,
        title_fr: row['title_fr'].presence || doc_type,
        title_de: nil,
        document_type: doc_type,
        base_code: code,
        edition_year: edition[:edition_year],
        edition_role: edition[:edition_role],
        editions: edition[:editions],
        category: doc_type,
        subcategory: nil,
        publication_date: (KNOWN_TAX_DATES[doc_type] || KNOWN_TAX_DATES[code])&.iso8601,
        effective_date: nil,
        end_date: nil,
        is_consolidated: true,
        is_in_force: true,
        preamble_nl: nil,
        preamble_fr: nil,
        source_url: nil,
        last_modified: nil,
        article_count: row['article_count']
      }
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] legislation_info error: #{e.message}")
      nil
    end
  end

  # ─── Editions of the annual codes ──────────────────────────────────────
  # WIB 92 and KB/WIB 92 are published once per INCOME year. Since 2026-09-26 the corpus
  # keeps each edition as its own tax_legislation row (base_code, edition_year,
  # edition_role): the edition for the current income year answers to the bare code
  # ('WIB 92'), the other one is 'WIB 92 (inkomsten 2027)'. So a page never lists two
  # editions' articles together, and each page names its own edition and links the others.
  #
  # Returns { base_code:, edition_year:, edition_role:, editions: [...] }, with nils and []
  # for a single-edition code or a corpus built before the edition columns existed.
  def self.edition_of(db, legislation_id)
    blank = { base_code: nil, edition_year: nil, edition_role: nil, editions: [] }
    columns = db.execute('PRAGMA table_info(tax_legislation)').map { |col| col.is_a?(Hash) ? col['name'] : col[1] }
    return blank unless (%w[base_code edition_year edition_role] - columns).empty?

    own = db.get_first_row('SELECT base_code, edition_year, edition_role FROM tax_legislation WHERE id = ?',
                           [legislation_id])
    return blank if own.nil? || own['edition_year'].nil?

    siblings = db.execute(<<~SQL, [own['base_code']])
      SELECT id, document_type, edition_year, COALESCE(edition_role, 'current') AS edition_role
      FROM tax_legislation
      WHERE base_code = ? AND edition_year IS NOT NULL
      ORDER BY edition_year DESC
    SQL
    {
      base_code: own['base_code'],
      edition_year: own['edition_year'].to_i,
      edition_role: own['edition_role'].presence || 'current',
      editions: siblings.map do |sib|
        { id: sib['id'], numac: numac_for(sib['id']), document_type: sib['document_type'],
          edition_year: sib['edition_year'].to_i, edition_role: sib['edition_role'] }
      end
    }
  rescue SQLite3::Exception => e
    Rails.logger.error("[FisconetSearch] edition_of error: #{e.message}")
    blank
  end

  # "inkomsten 2026 (aanslagjaar 2027)". Fisconet names editions by income year, and the
  # income of year Y is assessed in aanslagjaar Y + 1 (KB/WIB 92 art. 200; the 2026 edition of
  # KB/WIB 92 art. 4 is headed "inkomsten 2026 - aanslagjaar 2027").
  def self.edition_label(edition_year, language_id: 1)
    year = edition_year.to_i
    return nil if year.zero?

    if language_id.to_i == 2
      "revenus #{year} (exercice d'imposition #{year + 1})"
    else
      "inkomsten #{year} (aanslagjaar #{year + 1})"
    end
  end

  # ─── All articles for a given legislation ──────────────────────────────
  # @param legislation_id [Integer]
  # @param language_id [Integer] 1=NL, 2=FR
  # @return [Array<Hash>]
  def self.all_articles(legislation_id:, language_id: 1)
    return [] unless File.exist?(FISCONET_DB_PATH)

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      # Walk-corpus schema: no section_path or display_order. The region
      # columns are richer than what they replace: grouping by region label
      # gives the page's table of contents the four regional variants of
      # W.Succ./W.Reg. as sections - which the old single-variant corpus
      # could never show at all. Federal/unregionalized articles carry no
      # section, exactly like before.
      # The pdf:* rows are the walk's internal whole-code consolidation
      # slices (gap-fill source material), not articles; rendering one 500'd
      # the BTW page on its deeply nested PDF-conversion markup.
      rows = db.execute(<<~SQL, [legislation_id])
        SELECT a.id, a.article_number, a.article_title, a.article_type,
               a.text_nl, a.text_fr, a.html_nl, a.html_fr,
               a.region, a.region_nl, a.region_fr, a.version_date, a.end_date
        FROM tax_articles a
        WHERE a.legislation_id = ?
          AND a.article_number_src NOT LIKE 'pdf:%'
          -- Four KB/WIB 92 Annex III rows store an undecoded PDF container as
          -- their text ('%PDF-1.5 %...'). Their article_number is
          -- 'bijlage:III@...', so the pdf:* rule above does not reach them and
          -- the page renders the binary. Anchored at the start so a law that
          -- merely mentions PDF is untouched. Decoding them needs PyMuPDF,
          -- which is not installed on the host.
          AND substr(LTRIM(COALESCE(a.text_nl, '')), 1, 4) <> '%PDF'
          AND substr(LTRIM(COALESCE(a.text_fr, '')), 1, 4) <> '%PDF'
        ORDER BY COALESCE(a.region, ''), CAST(a.article_number AS INTEGER), a.article_number, a.id
      SQL

      db.close

      text_col = language_id == 2 ? 'text_fr' : 'text_nl'
      html_col = language_id == 2 ? 'html_fr' : 'html_nl'
      region_col = language_id == 2 ? 'region_fr' : 'region_nl'

      rows.map do |row|
        text = row[text_col]
        html = row[html_col]

        # Skip articles with no content in the requested language
        next nil unless text.present?

        # Strip URL artifacts from both text and HTML
        text = text.to_s.gsub(/\bwww\.fisconetplus\.be\b/, '').strip
        html = html.to_s.gsub(/\bwww\.fisconetplus\.be\b/, '').strip if html.present?

        # Oversized HTML is invariably deep PDF-conversion nesting that blows
        # the sanitizer's document-depth limit (the 2 MB KB/WIB 92 annex
        # 500'd the whole page). Dropping it here makes the view render the
        # clean plain text instead, which is what readers actually need.
        html = nil if html.present? && html.bytesize > 300_000

        {
          id: row['id'],
          article_number: row['article_number'],
          article_title: row['article_title'],
          # Exposed so the caller can tell a rate-table ENTRY from a provision.
          # Table entries name a good or service and are legitimately short
          # ("XIII. Waterdistributie..."), so a length-based garbage filter
          # cannot be applied to them the way it can to an article.
          article_type: row['article_type'],
          text: text,
          html: html.presence,
          section_path: row[region_col].presence,
          end_date: row['end_date']
        }
      end.compact
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] all_articles error: #{e.message}")
      []
    end
  end

  # ─── All legislation records ───────────────────────────────────────────
  # @return [Array<Hash>] All legislation rows with article counts
  def self.all_legislations
    return [] unless File.exist?(FISCONET_DB_PATH)

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      rows = db.execute(<<~SQL)
        SELECT l.id, l.title_nl, l.title_fr, l.document_type,
               (SELECT COUNT(*) FROM tax_articles WHERE legislation_id = l.id) AS article_count
        FROM tax_legislation l
        ORDER BY l.id
      SQL

      db.close

      rows.map do |row|
        {
          id: row['id'],
          fisconet_id: nil,
          numac_real: REAL_NUMACS[row['document_type']],
          title_nl: row['title_nl'].presence || row['document_type'],
          title_fr: row['title_fr'].presence || row['document_type'],
          document_type: row['document_type'],
          category: row['document_type'],
          source_url: nil,
          is_in_force: true,
          article_count: row['article_count']
        }
      end
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] all_legislations error: #{e.message}")
      []
    end
  end

  # ─── Single article lookup ─────────────────────────────────────────────
  def self.find(id)
    return nil unless File.exist?(FISCONET_DB_PATH)

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      row = db.get_first_row(<<~SQL, [id])
        SELECT a.id, a.legislation_id, a.article_number, a.article_title,
               a.text_nl, a.text_fr, a.region_nl,
               l.title_nl, l.title_fr, l.document_type
        FROM tax_articles a
        JOIN tax_legislation l ON a.legislation_id = l.id
        WHERE a.id = ?
      SQL

      db.close
      return nil unless row

      {
        id: row['id'],
        type: 'fisconet',
        article_number: row['article_number'],
        section_path: row['region_nl'],
        text_nl: row['text_nl'],
        text_fr: row['text_fr'],
        legislation_title_nl: row['title_nl'],
        legislation_title_fr: row['title_fr'],
        document_type: row['document_type'] || 'WIB 92',
        fisconet_id: nil
      }
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] Database error: #{e.message}")
      nil
    end
  end

  # ─── Stats ─────────────────────────────────────────────────────────────
  def self.stats
    return {} unless File.exist?(FISCONET_DB_PATH)

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)

      article_count = db.get_first_value('SELECT COUNT(*) FROM tax_articles')
      legislation_count = db.get_first_value('SELECT COUNT(*) FROM tax_legislation')

      db.close

      {
        articles: article_count,
        legislation: legislation_count,
        available: true
      }
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] Stats error: #{e.message}")
      { available: false, error: e.message }
    end
  end

  # ─── Availability ──────────────────────────────────────────────────────
  def self.available?
    File.exist?(FISCONET_DB_PATH)
  end
end
