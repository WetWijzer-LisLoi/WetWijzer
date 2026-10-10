# frozen_string_literal: true

module ParliamentaryRelations
  # A law's preparatory works for the related-sources panel: the federal
  # documents of the Chamber corpus, found through Filter, and, counted apart,
  # the documents the Flemish Parliament's own records link to a decree. A
  # store that is missing or does not answer makes its part :unavailable,
  # never an empty list.
  class Resolver
    # status:   :verified (a reviewed relation), :unverified (the corpus's
    #           automatic links), :empty or :unavailable
    # count:    the documents the filter selects in the site's document language
    # dossiers: the reviewed or referenced dossiers, for their official pages
    Result = Data.define(:status, :basis, :items, :count, :dossiers, :vlaams) do
      def verified? = status == :verified
      def unavailable? = status == :unavailable || vlaams&.status == :unavailable
    end

    # status: :linked or :unavailable; nil stands for no Vlaams documents
    Vlaams = Data.define(:status, :items, :count)

    VLAAMS_SQL = 'SELECT id, titel, document_type, nummer, zittingsjaar, pdf_url FROM documents WHERE numac = ? ' \
                 'ORDER BY zittingsjaar, CAST(nummer AS INTEGER), id LIMIT ?'

    def initialize(numac, locale: I18n.locale)
      @numac = numac.to_s
      @language = ParliamentaryRelations.document_language(locale)
    end

    def call
      Result.new(**federal, vlaams: vlaams)
    end

    private

    def federal
      path = ParliamentaryRelations.chamber_db_path
      return unavailable('the Chamber corpus is missing') unless File.exist?(path)

      db = ParliamentaryRelations.chamber_db(path)
      filter = Filter.for(@numac, db, language: @language)
      return { status: :empty, basis: nil, items: [], count: nil, dossiers: [] } unless filter

      items = filter.preview(db, language: @language)
      items = filter.dossier_summaries(db) if items.empty? && filter.basis == :dossier_refs
      { status: filter.verified? ? :verified : :unverified, basis: filter.basis, items: items,
        count: filter.count(db, language: @language), dossiers: filter.dossiers }
    rescue SQLite3::Exception, ActiveRecord::ActiveRecordError => e
      unavailable(e.message)
    end

    def unavailable(reason)
      Rails.logger.warn("[ParliamentaryRelations] #{@numac}: #{reason}")
      { status: :unavailable, basis: nil, items: [], count: nil, dossiers: [] }
    end

    def vlaams
      path = ParliamentaryRelations.vlaams_db_path
      unless File.exist?(path)
        # Deployments without the optional Vlaams corpus may omit it. An
        # explicitly configured source that disappeared is a read failure,
        # so callers report it and do not cache the incomplete panel.
        return unless ENV.key?('VLAAMSE_CODEX_DB')

        return unavailable_vlaams('the configured corpus is missing')
      end

      db = SQLite3::Database.new(path, readonly: true)
      db.busy_timeout = 5000
      count = db.execute('SELECT COUNT(*) FROM documents WHERE numac = ?', [@numac]).first.first.to_i
      return if count.zero?

      items = db.execute(VLAAMS_SQL, [@numac, PREVIEW_LIMIT]).map do |id, title, type, number, session, pdf|
        { id: id, title: title, document_type: type, label: [session, number].compact_blank.join(' nr. '),
          pdf_url: pdf.presence }
      end
      Vlaams.new(status: :linked, items: items, count: count)
    rescue SQLite3::Exception => e
      unavailable_vlaams(e.message)
    ensure
      db&.close
    end

    def unavailable_vlaams(reason)
      Rails.logger.warn("[ParliamentaryRelations] #{@numac}: Vlaams store: #{reason}")
      Vlaams.new(status: :unavailable, items: [], count: nil)
    end
  end
end
