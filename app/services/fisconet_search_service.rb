# frozen_string_literal: true

# == FisconetSearchService
#
# Service for searching WIB 92 (Income Tax Code) articles from the FisconetPlus database.
# Returns results that duck-type with Legislation model for unified display.
#
# The fisconet database is separate from the main legislation database because
# WIB 92 is no longer available on Justel (NUMAC redirects to FisconetPlus).
#
# @example Basic usage
#   results = FisconetSearchService.search(title: 'aftrek', lang_nl: '1')
#   results.each do |article|
#     puts "#{article.title}: #{article.article_number}"
#   end
#
class FisconetSearchService
  # Wrapper class that duck-types with Legislation for unified rendering
  class FisconetResult
    attr_reader :id, :numac, :title, :date, :language_id, :law_type_id,
                :is_abolished, :is_empty_content, :tags, :justel, :reflex,
                :article_number, :section_path, :text_preview, :fisconet_id,
                :document_type, :fisconet_source

    def initialize(attrs)
      @id = attrs[:id]
      @numac = attrs[:numac] || "FISCONET_#{attrs[:id]}"
      @title = attrs[:title]
      @date = attrs[:date] || Date.new(1992, 1, 1)
      @language_id = attrs[:language_id] || 1
      @law_type_id = 2 # Treat as "Wet"
      @is_abolished = false
      @is_empty_content = false
      @tags = nil
      @justel = 'N/A'
      @reflex = 'N/A'
      @article_number = attrs[:article_number]
      @section_path = attrs[:section_path]
      @text_preview = attrs[:text_preview]
      @fisconet_id = attrs[:fisconet_id]
      @document_type = attrs[:document_type] || 'WIB 92'
      @fisconet_source = true # Flag to identify FisconetPlus source
    end

    # Duck-type methods for compatibility with Legislation
    def fisconet?
      true
    end

    def fisconet_url
      return nil unless @fisconet_id
      "https://eservices.minfin.fgov.be/myminfin-web/pages/fisconet?document=#{@fisconet_id}"
    end
  end

  FISCONET_DB_PATH = ENV.fetch('FISCONET_DB',
    Rails.root.join('lib/wetwijzer_updater/fisconet_scraper/fisconet.sqlite3').to_s)

  # Maximum results to return per search
  MAX_RESULTS = 50

  # Search fisconet articles
  # @param params [Hash] Search parameters
  # @option params [String] :title Search term
  # @option params [String] :lang_nl '1' to include Dutch
  # @option params [String] :lang_fr '1' to include French
  # @return [Array<Hash>] Array of article hashes with legislation-like structure
  def self.search(params)
    return [] unless File.exist?(FISCONET_DB_PATH)

    title = params[:title]&.strip
    return [] if title.blank?

    # Determine which language columns to search
    include_nl = params[:lang_nl] == '1' || (!params[:lang_nl].present? && !params[:lang_fr].present?)
    include_fr = params[:lang_fr] == '1'

    results = []
    
    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      # Build search query
      search_term = "%#{title.downcase}%"
      
      # Search in article text and number
      query = <<~SQL
        SELECT a.id, a.article_number, a.text_nl, a.text_fr, a.section_path,
               l.title_nl, l.title_fr, l.document_type, l.fisconet_id
        FROM tax_articles a
        JOIN tax_legislation l ON a.legislation_id = l.id
        WHERE (
          LOWER(a.article_number) LIKE ?
          OR LOWER(a.text_nl) LIKE ?
          OR LOWER(a.text_fr) LIKE ?
          OR LOWER(a.section_path) LIKE ?
        )
        ORDER BY 
          CASE WHEN LOWER(a.article_number) LIKE ? THEN 0 ELSE 1 END,
          a.id
        LIMIT ?
      SQL

      db.execute(query, [search_term, search_term, search_term, search_term, search_term, MAX_RESULTS]).each do |row|
        # Skip if language doesn't match
        has_nl = row['text_nl'].present?
        has_fr = row['text_fr'].present?
        next unless (include_nl && has_nl) || (include_fr && has_fr)

        # Build result as FisconetResult object (duck-types with Legislation)
        text = include_nl && has_nl ? row['text_nl'] : row['text_fr']
        title_text = include_nl ? row['title_nl'] : row['title_fr']
        lang_id = (include_nl && has_nl) ? 1 : 2

        # Build title like: "WIB 92 - Art. 123 - Section Path"
        full_title = "#{row['document_type'] || 'WIB 92'} - Art. #{row['article_number']}"
        full_title += " - #{row['section_path']}" if row['section_path'].present?

        results << FisconetResult.new(
          id: row['id'],
          article_number: row['article_number'],
          section_path: row['section_path'],
          text_preview: text&.slice(0, 300),
          title: full_title,
          document_type: row['document_type'] || 'WIB 92',
          fisconet_id: row['fisconet_id'],
          language_id: lang_id
        )
      end

      db.close
    rescue SQLite3::Exception => e
      Rails.logger.error("[FisconetSearch] Database error: #{e.message}")
    end

    results
  end

  # Get a single article by ID
  # @param id [Integer] Article ID
  # @return [Hash, nil] Article hash or nil if not found
  def self.find(id)
    return nil unless File.exist?(FISCONET_DB_PATH)

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      db.results_as_hash = true

      row = db.get_first_row(<<~SQL, [id])
        SELECT a.*, l.title_nl, l.title_fr, l.document_type, l.fisconet_id
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

  # Get statistics about the fisconet database
  # @return [Hash] Statistics hash
  def self.stats
    return {} unless File.exist?(FISCONET_DB_PATH)

    begin
      db = SQLite3::Database.new(FISCONET_DB_PATH)
      
      article_count = db.get_first_value("SELECT COUNT(*) FROM tax_articles")
      legislation_count = db.get_first_value("SELECT COUNT(*) FROM tax_legislation")
      
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

  # Check if fisconet database is available
  # @return [Boolean]
  def self.available?
    File.exist?(FISCONET_DB_PATH)
  end
end
