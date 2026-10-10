# frozen_string_literal: true

# WW-LINK-01: which parliamentary documents a law page may present as the
# law's preparatory works, decided once for the law page's panel, its "view
# all" list, the law's metadata and a parliamentary document's backlink.
#
# The Chamber corpus links a document to a law through
# documents.legislation_numac and a law to dossiers through
# legislation.parliamentary_refs. Both are written automatically (a title
# match, a dossier-wide propagation, the first dossier label in the law's
# parliamentary-work text) and neither records how sure it is: on 2026-10-08
# the Wetboek van economisch recht (2013A11134) carried 891 documents from 162
# dossiers and the dossier reference K:52-0008, 2008 annexes of a legislature
# before the code existed. A reviewed relation (config/parliamentary_relations.yml)
# names the exact dossiers that prepared a law, with the official evidence,
# and for such a law nothing else is shown. Every other law keeps its
# automatic links, presented as automatically linked and never as a verified
# count.
module ParliamentaryRelations
  PREVIEW_LIMIT = 10

  # The language of the documents a site lists. The Chamber publishes in Dutch
  # and French; the French documents serve the French, German and English
  # sites, as the parliamentary index always did.
  def self.document_language(locale = I18n.locale)
    locale.to_s == 'nl' ? 'nl' : 'fr'
  end

  def self.manifest
    Manifest.current
  end

  def self.chamber_db_path
    ENV.fetch('CHAMBER_DB') { Rails.root.join('storage', 'chamber.sqlite3').to_s }
  end

  # One connection per process for the multi-gigabyte store, reopened when the
  # path changes (tests point CHAMBER_DB elsewhere): opening it per request
  # cost about 500 ms.
  def self.chamber_db(path = chamber_db_path)
    @chamber_db = nil unless @chamber_db_path == path
    @chamber_db_path = path
    @chamber_db ||= SQLite3::Database.new(path).tap { |db| db.busy_timeout = 5000 }
  rescue SQLite3::Exception
    @chamber_db = nil
    raise
  end

  # The dossier links of a law page's metadata. A reviewed law shows its
  # reviewed dossiers, and a contents link only for a parliament its relation
  # does not cover; any other law shows what its contents row names (Justel's
  # own dossier fields), as before.
  def self.metadata_dossiers(numac, content, locale: I18n.locale)
    reviewed = manifest.for_law(numac)
    links = Array(reviewed&.dossiers).map do |dossier|
      { parliament: dossier.parliament, label: dossier.label, url: dossier.url(locale), verified: true }
    end
    covered = links.map { |link| link[:parliament] }
    if content
      { 'senate' => [content.senate_dossier_label, -> { content.senate_dossier_url(locale) }],
        'chamber' => [content.chamber_dossier_label, -> { content.chamber_dossier_url(locale) }] }.each do |parliament, (label, url)|
        next if covered.include?(parliament) || label.blank? || (href = url.call).blank?

        links << { parliament: parliament, label: label, url: href, verified: false }
      end
    end
    links.sort_by { |link| link[:parliament] == 'senate' ? 0 : 1 }
  end

  def self.vlaams_db_path
    ENV.fetch('VLAAMSE_CODEX_DB') { Rails.root.join('storage', 'vlaamse_codex.sqlite3').to_s }
  end

  # Every law a parliamentary document belongs to, for its backlink. A
  # reviewed dossier can prepare more than one distinct law (for example a
  # code and the Act that introduced it), so it deliberately returns every
  # reviewed relation rather than silently treating them as aliases.
  #
  # Each result is { numac:, status: :verified } for a reviewed dossier, or
  # the single { numac:, status: :unverified } corpus link when no reviewed
  # dossier applies. A corpus NUMAC owned by any reviewed relation is never
  # shown for another dossier: automatic metadata must not defeat review.
  def self.laws_for_document(parliament:, legislature:, dossier_number:, legislation_numac:)
    reviewed = manifest.for_dossier(parliament, legislature, dossier_number)
    return reviewed.map { |relation| { numac: relation.numac, status: :verified } }.uniq { |relation| relation[:numac] } if reviewed.any?
    return [] if legislation_numac.blank? || manifest.for_law(legislation_numac)

    [{ numac: legislation_numac, status: :unverified }]
  end

  # Compatibility for callers that only render one backlink. New callers
  # should use laws_for_document so separate laws remain separately visible.
  def self.law_for_document(**)
    laws_for_document(**).first
  end
end
