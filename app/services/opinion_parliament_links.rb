# frozen_string_literal: true

# The links between the Council of State's advisory opinions and the
# parliamentary documents that print or cite them, read from the small SQLite
# file lib/tasks/opinion_parliament_links.py writes every Sunday after
# ww-juris-linkage (docs/ops/opinion-parliament-links.md).
#
# The file lives BESIDE chamber.sqlite3, next to the real file the storage
# symlink points to on the server, so no deploy hook and no environment change
# is needed for it to be found; OPINION_PARLIAMENT_LINKS_DB overrides that.
# Everything here answers [] when the file, the table or the row is absent:
# until the first run has written the file, both pages simply show no link.
#
# Opinion rows are keyed RVSADV:<dotted number>:<NL|FR>. The links are keyed
# by the dotted number alone: an opinion cited as 44.539/AG in the French
# documents and 44.539/AV in the Dutch ones is one opinion, published under
# one or both suffixes. A link from a document carries that document's
# language suffix; JurisprudenceController redirects to the other suffix when
# only that one is published (moved_advisory_key).
module OpinionParliamentLinks
  FILE_NAME = 'opinion_parliament_links.sqlite3'
  OPINION_KEY = /\ARVSADV:(\d{1,3}\.\d{3}):(NL|FR)\z/
  # How long a page waits on the file while the weekly job commits a batch
  # (a few milliseconds each; the file is in rollback-journal mode, not WAL).
  BUSY_TIMEOUT_MS = 500
  MAX_ROWS = 50

  module_function

  # @return [String, nil] the dotted number of an advisory opinion key
  def opinion_number(case_number)
    OPINION_KEY.match(case_number.to_s)&.captures&.first
  end

  # The parliamentary documents citing the opinion behind a case key, one per
  # document (parliament, legislature, dossier, number), in the page's
  # language where the Chamber printed both, oldest first.
  #
  # @param case_number [String] an RVSADV key; any other key answers []
  # @param language [String] 'nl' or 'fr', the page's language
  # @return [Array<Hash>] :id, :parliament, :legislature, :dossier_number,
  #   :document_number, :language, :document_date
  def documents_for(case_number, language:)
    number = opinion_number(case_number)
    return [] unless number

    rows = query(
      'SELECT document_id, parliament, legislature, dossier_number, document_number, language, document_date ' \
      'FROM opinion_parliament_links WHERE opinion_number = ? ORDER BY document_date, document_id LIMIT ?',
      [number, MAX_ROWS * 2]
    )
    documents = rows.map do |row|
      { id: row[0], parliament: row[1], legislature: row[2], dossier_number: row[3],
        document_number: row[4], language: row[5], document_date: row[6] }
    end
    preferred = language.to_s == 'fr' ? 'fr' : 'nl'
    documents
      .group_by { |doc| doc.values_at(:parliament, :legislature, :dossier_number, :document_number) }
      .map { |_, versions| versions.find { |doc| doc[:language] == preferred } || versions.first }
      .sort_by { |doc| [doc[:document_date].to_s, doc[:id].to_i] }
      .first(MAX_ROWS)
  end

  # The opinions a parliamentary document prints or cites, highest number
  # first, each with the key its link should open.
  #
  # @param document_id [Integer] documents.id in chamber.sqlite3
  # @param language [String] the document's language, 'nl' or 'fr'
  # @return [Array<Hash>] :number ('44.539') and :key ('RVSADV:44.539:NL')
  def opinions_for(document_id, language:)
    return [] if document_id.blank?

    suffix = language.to_s == 'fr' ? 'FR' : 'NL'
    rows = query(
      'SELECT opinion_number FROM opinion_parliament_links WHERE document_id = ? LIMIT ?',
      [document_id.to_i, MAX_ROWS]
    )
    rows.map(&:first)
        .uniq
        .sort_by { |number| -number.delete('.').to_i }
        .map { |number| { number: number, key: "RVSADV:#{number}:#{suffix}" } }
  end

  def db_path
    ENV['OPINION_PARLIAMENT_LINKS_DB'].presence || File.join(File.dirname(real_chamber_path), FILE_NAME)
  end

  # storage/chamber.sqlite3 is a symlink to the corpus on the volume; the
  # links file sits next to the real file, where the job writes it.
  def real_chamber_path
    path = ENV.fetch('CHAMBER_DB') { Rails.root.join('storage', 'chamber.sqlite3').to_s }
    File.exist?(path) ? File.realpath(path) : path
  rescue SystemCallError
    path
  end

  # One short-lived read-only handle per query: the file is tiny, the pages
  # read it once each, and the weekly job replaces it row by row.
  def query(sql, params)
    path = db_path
    return [] unless File.exist?(path)

    db = SQLite3::Database.new(path, readonly: true)
    db.busy_timeout = BUSY_TIMEOUT_MS
    db.execute(sql, params)
  rescue SQLite3::Exception => e
    Rails.logger.warn("OpinionParliamentLinks: #{e.class}: #{e.message} (#{path})")
    []
  ensure
    db&.close
  end
end
