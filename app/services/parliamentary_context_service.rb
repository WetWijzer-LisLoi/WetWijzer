# frozen_string_literal: true

require 'sqlite3'

# Legacy/dormant NUMAC-context utility for querying parliamentary documents
# from the separate Chamber database.
class ParliamentaryContextService
  CHAMBER_DB_PATH = Rails.root.join('storage', 'chamber.sqlite3').to_s
  MAX_DOCUMENTS = 50

  def initialize(language: 'nl')
    # Keep the chatbot's source language rule identical to the law-page
    # resolver: Dutch gets Dutch documents; every other locale gets French.
    @language = ParliamentaryRelations.document_language(language.to_s.downcase)
  end

  # Check if parliamentary database exists
  def self.available?
    File.file?(chamber_db_path)
  end

  def self.chamber_db_path
    ENV.fetch('CHAMBER_DB') { CHAMBER_DB_PATH }
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

    limit = bounded_limit(limit)
    reviewed = ParliamentaryRelations.manifest.for_law(numac)

    with_database do |db|
      # A reviewed relation is an exact, human-approved dossier predicate.
      # Never supplement it with automatic NUMAC or dossier_links rows: both
      # are corpus hints and may point at unrelated later amendments.
      return reviewed_documents(db, reviewed.dossiers, limit) if reviewed

      # Ordinary laws retain the historic order: their direct NUMAC relation
      # first, then the corpus's dossier_links fallback.
      docs = db.execute(<<~SQL, [numac.to_s, @language, limit])
        SELECT parliament, legislature, dossier_number, document_number,
               document_type, title, content, pdf_url
        FROM documents
        WHERE legislation_numac = ? AND language = ?
        ORDER BY parliament, legislature, dossier_number, document_number
        LIMIT ?
      SQL

      return docs unless docs.empty?
      return [] unless dossier_links_table?(db)

      db.execute(<<~SQL, [numac.to_s, @language, limit])
        SELECT DISTINCT d.parliament, d.legislature, d.dossier_number,
               d.document_number, d.document_type, d.title, d.content, d.pdf_url
        FROM dossier_links dl
        JOIN documents d ON dl.parliament = d.parliament
          AND dl.legislature = d.legislature
          AND dl.dossier_number = d.dossier_number
        WHERE dl.legislation_numac = ? AND d.language = ?
        ORDER BY d.parliament, d.legislature, d.dossier_number, d.document_number
        LIMIT ?
      SQL
    end
  rescue SQLite3::Exception => e
    Rails.logger.warn("Parliamentary DB query error: #{e.message}")
    []
  end

  # Get dossier links for a NUMAC (without content)
  def dossier_links_for_numac(numac)
    return [] unless self.class.available?

    reviewed = ParliamentaryRelations.manifest.for_law(numac)
    return reviewed.dossiers.map { |dossier| reviewed_dossier_link(dossier) } if reviewed

    with_database do |db|
      return [] unless dossier_links_table?(db)

      db.execute(<<~SQL, [numac.to_s])
        SELECT parliament, legislature, dossier_number
        FROM dossier_links
        WHERE legislation_numac = ?
      SQL
    end
  rescue SQLite3::Exception => e
    Rails.logger.warn("Parliamentary DB query error: #{e.message}")
    []
  end

  # Get database statistics
  def self.stats
    return {} unless available?

    db = SQLite3::Database.new(chamber_db_path, readonly: true)
    db.busy_timeout = 5000
    {
      total_documents: db.get_first_value('SELECT COUNT(*) FROM documents').to_i,
      with_content: db.get_first_value("SELECT COUNT(*) FROM documents WHERE content IS NOT NULL AND content != ''").to_i,
      linked_numacs: db.get_first_value('SELECT COUNT(DISTINCT legislation_numac) FROM documents WHERE legislation_numac IS NOT NULL').to_i
    }
  rescue SQLite3::Exception => e
    Rails.logger.error("Parliamentary stats error: #{e.message}")
    {}
  ensure
    db&.close
  end

  private

  def with_database
    db = SQLite3::Database.new(self.class.chamber_db_path, readonly: true)
    db.results_as_hash = true
    db.busy_timeout = 5000
    yield db
  ensure
    db&.close
  end

  def bounded_limit(value)
    value.to_i.clamp(1, MAX_DOCUMENTS)
  end

  # Older, read-only Chamber snapshots did not always include this optional
  # automatic-link table. Treat its absence as no fallback, not an error that
  # is logged once for every request.
  def dossier_links_table?(db)
    db.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'dossier_links' LIMIT 1") == 1
  end

  def reviewed_documents(db, dossiers, limit)
    predicates = dossiers.map do |dossier|
      variants = dossier.number_variants
      "(parliament = ? AND legislature = ? AND dossier_number IN (#{(['?'] * variants.length).join(', ')}))"
    end
    binds = dossiers.flat_map { |dossier| [dossier.parliament, dossier.legislature, *dossier.number_variants] }

    db.execute(<<~SQL, [@language, *binds, limit])
      SELECT parliament, legislature, dossier_number, document_number,
             document_type, title, content, pdf_url
      FROM documents
      WHERE language = ? AND (#{predicates.join(' OR ')})
      ORDER BY parliament, legislature, dossier_number, document_number
      LIMIT ?
    SQL
  end

  def reviewed_dossier_link(dossier)
    { 'parliament' => dossier.parliament, 'legislature' => dossier.legislature,
      'dossier_number' => dossier.number.to_s }
  end

  def format_documents(docs, max_content_length)
    header = @language == 'fr' ? '## Travaux préparatoires' : '## Voorbereidende werken'

    parts = [header]
    helper = Object.new.extend(ParliamentaryHelper)

    docs.each do |doc|
      parliament = doc['parliament']&.capitalize || 'Unknown'
      dossier = "#{doc['legislature']}-#{doc['dossier_number']}"
      doc_num = doc['document_number'] || ''
      doc_type = doc['document_type'] || 'document'
      title = doc['title'] || ''

      parts << "### #{parliament} #{dossier}/#{doc_num} (#{doc_type})"
      # A site page title ("Request Rejected", the search page's heading) is
      # not the document's; the heading above already identifies it.
      parts << "**#{title}**" unless ParliamentaryHelper.generic_parl_title?(title)

      if doc['content'].present?
        # Filter bilingual content before truncating for the chatbot prompt
        filtered = helper.filter_bilingual_content(doc['content'], @language)
        content = filtered[0, max_content_length]
        content += '...' if filtered.length > max_content_length
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
