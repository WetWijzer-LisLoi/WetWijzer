# frozen_string_literal: true

module ParliamentaryRelations
  # How a law's federal documents are found in the Chamber corpus. The law
  # page's panel and the parliamentary index's "view all" list use the same
  # filter, so they count and list the same documents:
  #   :reviewed      the exact dossiers of the law's reviewed relation
  #   :numac         documents.legislation_numac, written automatically
  #   :dossier_refs  the Chamber dossiers legislation.parliamentary_refs names,
  #                  also written automatically
  # Every query is bound and indexed: idx_documents_unique serves the dossier
  # filters, idx_documents_numac the NUMAC one.
  class Filter
    # The parliamentary order: legislature, dossier, document number. The
    # corpus's document_date cannot order them: 53K2543003, an amendment of
    # 08/01/2013, is dated 2008-04-03 in French and 2003-04-03 in Dutch.
    ORDER = 'legislature, CAST(dossier_number AS INTEGER), document_number, id'
    COLUMNS = 'id, parliament, legislature, dossier_number, document_number, title, document_type'
    # the dossier part of "K:55-1234" or "K:55 1234", as Content#parse_chamber_pair reads it
    DOSSIER = /\A\s*(\d{1,3})[ \t\u00A0\u202F\-‑–]+(\d{1,7})\s*\z/

    attr_reader :basis, :numac, :dossiers

    def self.for(numac, db, language:)
      reviewed = ParliamentaryRelations.manifest.for_law(numac)
      return new(:reviewed, numac, reviewed.dossiers) if reviewed

      by_numac = new(:numac, numac)
      return by_numac if by_numac.count(db, language:).positive?

      refs = dossier_refs(numac)
      new(:dossier_refs, numac, refs) if refs.any?
    end

    # The Chamber dossiers a law's parliamentary_refs name. Senate refs
    # ("S:...") were never looked up here and still are not.
    def self.dossier_refs(numac)
      raw = Legislation.where(numac: numac.to_s).where.not(parliamentary_refs: [nil, '']).pick(:parliamentary_refs)
      Array(JSON.parse(raw.presence || '[]')).filter_map do |ref|
        match = ref.to_s.start_with?('K:') && DOSSIER.match(ref.to_s.delete_prefix('K:'))
        next unless match

        Manifest::Dossier.new(parliament: 'chamber', legislature: match[1].to_i, number: match[2].to_i,
                              evidence_url: nil)
      end.uniq
    rescue JSON::ParserError
      []
    end

    def initialize(basis, numac, dossiers = [])
      @basis = basis
      @numac = numac.to_s
      @dossiers = dossiers
      @counts = {}
    end

    def verified? = basis == :reviewed

    # [sql, binds] selecting the filter's documents in every language
    def where
      return ['legislation_numac = ?', [numac]] if basis == :numac

      clauses = dossiers.map do |dossier|
        "(parliament = ? AND legislature = ? AND dossier_number IN (#{(['?'] * dossier.number_variants.size).join(', ')}))"
      end
      ["(#{clauses.join(' OR ')})", dossiers.flat_map { |d| [d.parliament, d.legislature, *d.number_variants] }]
    end

    def count(db, language:)
      @counts[language] ||= begin
        sql, binds = where
        db.execute("SELECT COUNT(*) FROM documents WHERE #{sql} AND language = ?", binds + [language]).first.first.to_i
      end
    end

    def preview(db, language:, limit: PREVIEW_LIMIT)
      sql, binds = where
      db.execute("SELECT #{COLUMNS} FROM documents WHERE #{sql} AND language = ? ORDER BY #{ORDER} LIMIT ?",
                 binds + [language, limit]).map do |id, parliament, legislature, dossier, number, title, type|
        { id: id, parliament: parliament, legislature: legislature, dossier_number: dossier, document_number: number,
          title: title, document_type: type }
      end
    end

    # A referenced dossier whose documents are not in the corpus yet: its
    # summary row, which links to the official page.
    def dossier_summaries(db)
      dossiers.filter_map do |dossier|
        row = db.execute('SELECT id, titel, type, dossier_url FROM dossiers WHERE legislature = ? AND nummer = ? LIMIT 1',
                         [dossier.legislature, dossier.number]).first
        next unless row

        { id: row[0], parliament: 'chamber', legislature: dossier.legislature, dossier_number: dossier.label,
          title: row[1], document_type: row[2], dossier_url: row[3].presence || dossier.url, source: :dossier_summary }
      end
    end
  end
end
