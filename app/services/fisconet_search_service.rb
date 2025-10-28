# frozen_string_literal: true

# == FisconetSearchService
#
# Service for searching tax legislation articles from the FisconetPlus database.
# Returns ONE result per distinct legislation that has a matching article, so
# each law appears as a single entry in search results — just like Justel laws.
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
  # Does NOT respond to fisconet? — so _law.html.erb renders a normal Details link.
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

  # ─── Search ────────────────────────────────────────────────────────────
  # Returns ONE FisconetResult per distinct legislation that has a matching article.
  #
  # @param params [Hash] Search parameters (:title, :lang_nl, :lang_fr)
  # @return [Array<FisconetResult>]
  def self.search(params)
    return [] unless File.exist?(FISCONET_DB_PATH)

    title = params[:title]&.strip
    return [] if title.blank?

    include_nl = params[:lang_nl] == '1' || (!params[:lang_nl].present? && !params[:lang_fr].present?)
    lang_id = include_nl ? 1 : 2

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      search_term = "%#{title.downcase}%"

      # Find distinct legislation IDs that have at least one matching article
      rows = db.execute(<<~SQL, [search_term, search_term, search_term, search_term])
        SELECT DISTINCT l.id, l.title_nl, l.title_fr, l.document_type,
               l.publication_date, l.source_url, l.is_in_force
        FROM tax_articles a
        JOIN tax_legislation l ON a.legislation_id = l.id
        WHERE (
          LOWER(a.article_number) LIKE ?
          OR LOWER(a.text_nl)     LIKE ?
          OR LOWER(a.text_fr)     LIKE ?
          OR LOWER(a.section_path) LIKE ?
        )
      SQL

      db.close

      rows.map do |row|
        title_nl = row['title_nl']
        title_fr = row['title_fr']
        doc_type = row['document_type'] || 'WIB 92'

        # Use the DB title directly (already includes short name in parentheses)
        display_title = lang_id == 2 ? (title_fr || title_nl) : (title_nl || title_fr)

        pub_date = begin
          Date.parse(row['publication_date'].to_s)
        rescue StandardError
          nil
        end

        FisconetResult.new(
          id: row['id'],
          numac: numac_for(row['id']),
          title: display_title,
          date: pub_date,
          document_type: lang_id == 2 && doc_type == 'WIB 92' ? 'CIR 92' : doc_type,
          language_id: lang_id,
          source_url: row['source_url'],
          is_in_force: row['is_in_force']
        )
      end
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] Database error: #{e.message}")
      []
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

      row = db.get_first_row(<<~SQL, [legislation_id])
        SELECT l.id, l.fisconet_id, l.numac, l.document_number,
               l.title_nl, l.title_fr, l.title_de,
               l.document_type, l.category, l.subcategory,
               l.publication_date, l.effective_date, l.end_date,
               l.is_consolidated, l.is_in_force,
               l.preamble_nl, l.preamble_fr,
               l.source_url, l.last_modified,
               (SELECT COUNT(*) FROM tax_articles WHERE legislation_id = l.id) AS article_count
        FROM tax_legislation l
        WHERE l.id = ?
      SQL

      db.close
      return nil unless row

      {
        id: row['id'],
        fisconet_id: row['fisconet_id'],
        numac_real: row['numac'],
        document_number: row['document_number'],
        title_nl: row['title_nl'],
        title_fr: row['title_fr'],
        title_de: row['title_de'],
        document_type: row['document_type'],
        category: row['category'],
        subcategory: row['subcategory'],
        publication_date: row['publication_date'],
        effective_date: row['effective_date'],
        end_date: row['end_date'],
        is_consolidated: row['is_consolidated'] == 1,
        is_in_force: row['is_in_force'] == 1,
        preamble_nl: row['preamble_nl'],
        preamble_fr: row['preamble_fr'],
        source_url: row['source_url'],
        last_modified: row['last_modified'],
        article_count: row['article_count']
      }
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] legislation_info error: #{e.message}")
      nil
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

      rows = db.execute(<<~SQL, [legislation_id])
        SELECT a.id, a.article_number, a.article_title,
               a.text_nl, a.text_fr, a.html_nl, a.html_fr,
               a.section_path, a.display_order, a.version_date, a.end_date
        FROM tax_articles a
        WHERE a.legislation_id = ?
        ORDER BY CAST(a.article_number AS INTEGER), a.article_number, a.id
      SQL

      db.close

      text_col = language_id == 2 ? 'text_fr' : 'text_nl'
      html_col = language_id == 2 ? 'html_fr' : 'html_nl'

      rows.map do |row|
        text = row[text_col]
        html = row[html_col]

        # Skip articles with no content in the requested language
        next nil unless text.present?

        # Strip URL artifacts from both text and HTML
        text = text.to_s.gsub(/\bwww\.fisconetplus\.be\b/, '').strip
        html = html.to_s.gsub(/\bwww\.fisconetplus\.be\b/, '').strip if html.present?

        {
          id: row['id'],
          article_number: row['article_number'],
          article_title: row['article_title'],
          text: text,
          html: html.presence,
          section_path: row['section_path'],
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
        SELECT l.id, l.fisconet_id, l.numac,
               l.title_nl, l.title_fr, l.document_type, l.category,
               l.source_url, l.is_in_force,
               (SELECT COUNT(*) FROM tax_articles WHERE legislation_id = l.id) AS article_count
        FROM tax_legislation l
        ORDER BY l.id
      SQL

      db.close

      rows.map do |row|
        {
          id: row['id'],
          fisconet_id: row['fisconet_id'],
          numac_real: row['numac'],
          title_nl: row['title_nl'],
          title_fr: row['title_fr'],
          document_type: row['document_type'],
          category: row['category'],
          source_url: row['source_url'],
          is_in_force: row['is_in_force'] == 1,
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
               a.text_nl, a.text_fr, a.section_path,
               l.title_nl, l.title_fr, l.document_type, l.fisconet_id
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
        section_path: row['section_path'],
        text_nl: row['text_nl'],
        text_fr: row['text_fr'],
        legislation_title_nl: row['title_nl'],
        legislation_title_fr: row['title_fr'],
        document_type: row['document_type'] || 'WIB 92',
        fisconet_id: row['fisconet_id']
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
