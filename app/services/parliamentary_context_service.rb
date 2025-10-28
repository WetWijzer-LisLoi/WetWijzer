# frozen_string_literal: true

require 'sqlite3'

# Service to query parliamentary documents from the separate parliamentary database
# Used by LegalChatbotService to enrich answers with preparatory documents
class ParliamentaryContextService
  PARLIAMENTARY_DB_PATH = Rails.root.join('storage', 'parliamentary.sqlite3').to_s

  def initialize(language: 'nl')
    @language = language
  end

  # Check if parliamentary database exists
  def self.available?
    File.exist?(PARLIAMENTARY_DB_PATH)
  end

  # Get parliamentary context for a NUMAC
  # Returns formatted string for chatbot prompt
  def context_for_numac(numac, max_docs: 3, max_content_length: 1500)
    return nil unless self.class.available?

    docs = documents_for_numac(numac, limit: max_docs)
    return nil if docs.empty?

    format_documents(docs, max_content_length)
  rescue SQLite3::Exception => e
    Rails.logger.warn("Parliamentary DB error: #{e.message}")
    nil
  end

  # Get raw documents for a NUMAC
  def documents_for_numac(numac, limit: 5)
    return [] unless self.class.available?

    db = SQLite3::Database.new(PARLIAMENTARY_DB_PATH)
    db.results_as_hash = true

    # First try direct numac link
    docs = db.execute(<<~SQL, [numac, limit])
      SELECT parliament, legislature, dossier_number, document_number,
             document_type, title, content, pdf_url
      FROM documents
      WHERE legislation_numac = ?
      ORDER BY parliament, legislature, dossier_number, document_number
      LIMIT ?
    SQL

    # If no direct link, try via dossier_links table
    if docs.empty?
      docs = db.execute(<<~SQL, [numac, limit])
        SELECT DISTINCT d.parliament, d.legislature, d.dossier_number,
               d.document_number, d.document_type, d.title, d.content, d.pdf_url
        FROM dossier_links dl
        JOIN documents d ON dl.parliament = d.parliament
          AND dl.legislature = d.legislature
          AND dl.dossier_number = d.dossier_number
        WHERE dl.legislation_numac = ?
        ORDER BY d.parliament, d.legislature, d.dossier_number, d.document_number
        LIMIT ?
      SQL
    end

    db.close
    docs
  rescue SQLite3::Exception => e
    Rails.logger.warn("Parliamentary DB query error: #{e.message}")
    []
  end

  # Get dossier links for a NUMAC (without content)
  def dossier_links_for_numac(numac)
    return [] unless self.class.available?

    db = SQLite3::Database.new(PARLIAMENTARY_DB_PATH)
    db.results_as_hash = true

    links = db.execute(<<~SQL, [numac])
      SELECT parliament, legislature, dossier_number
      FROM dossier_links
      WHERE legislation_numac = ?
    SQL

    db.close
    links
  rescue SQLite3::Exception => e
    Rails.logger.warn("Parliamentary DB query error: #{e.message}")
    []
  end

  # Get database statistics
  def self.stats
    return {} unless available?

    db = SQLite3::Database.new(PARLIAMENTARY_DB_PATH)

    stats = {}
    stats[:total_documents] = db.get_first_value('SELECT COUNT(*) FROM documents').to_i
    stats[:with_content] = db.get_first_value("SELECT COUNT(*) FROM documents WHERE content IS NOT NULL AND content != ''").to_i
    stats[:linked_numacs] = db.get_first_value('SELECT COUNT(DISTINCT legislation_numac) FROM documents WHERE legislation_numac IS NOT NULL').to_i

    db.close
    stats
  rescue SQLite3::Exception => e
    Rails.logger.error("Parliamentary stats error: #{e.message}")
    {}
  end

  private

  def format_documents(docs, max_content_length)
    header = @language == 'fr' ? '## Travaux préparatoires' : '## Voorbereidende werken'
    
    parts = [header]

    docs.each do |doc|
      parliament = doc['parliament']&.capitalize || 'Unknown'
      dossier = "#{doc['legislature']}-#{doc['dossier_number']}"
      doc_num = doc['document_number'] || ''
      doc_type = doc['document_type'] || 'document'
      title = doc['title'] || ''

      parts << "### #{parliament} #{dossier}/#{doc_num} (#{doc_type})"
      parts << "**#{title}**" if title.present?

      if doc['content'].present?
        content = doc['content'][0, max_content_length]
        content += '...' if doc['content'].length > max_content_length
        parts << content
      elsif doc['pdf_url'].present?
        label = @language == 'fr' ? 'PDF disponible' : 'PDF beschikbaar'
        parts << "[#{label}](#{doc['pdf_url']})"
      end

      parts << '' # Empty line between docs
    end

    parts.join("\n")
  end
end
