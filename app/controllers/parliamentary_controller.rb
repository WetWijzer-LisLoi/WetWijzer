# frozen_string_literal: true

# Controller for browsing and searching Belgian parliamentary preparatory works
class ParliamentaryController < ApplicationController
  # GET /parlement
  def index
    @title = case I18n.locale when :fr then 'Travaux Préparatoires' when :de then 'Parlamentarische Vorarbeiten' when :en then 'Parliamentary Work' else 'Parlementaire Voorbereidingen' end
    @query = params[:q].to_s.strip
    @parliament = params[:parliament].presence
    @year = params[:year].presence
    @legislature = params[:legislature].presence
    @numac = params[:numac].presence
    @page = [params[:page].to_i, 1].max
    @sort = params[:sort].presence || 'date_desc'

    per_page = 20
    offset = (@page - 1) * per_page

    db_path = ENV.fetch('CHAMBER_DB') { Rails.root.join('storage', 'chamber.sqlite3').to_s }
    unless File.exist?(db_path)
      @documents = []
      @total_count = 0
      @total_pages = 0
      @parliaments = []
      @years = Date.current.year.downto(2010).to_a
      @db_unavailable = true
      return
    end

    filters = { parliament: @parliament, year: @year, legislature: @legislature, numac: @numac }
    lang = I18n.locale == :nl ? 'nl' : 'fr'

    if @query.present? || filters.values.any?(&:present?)
      @documents = search_documents(@query, filters.merge(lang: lang), per_page, offset)
      @total_count = count_documents(@query, filters.merge(lang: lang))
    else
      @documents = recent_documents(per_page, offset)
      @total_count = total_documents_count(lang)
    end

    # Enrich documents with dossier status from the dossiers table
    enrich_with_dossier_status(@documents)

    @total_pages = (@total_count.to_f / per_page).ceil
    @parliaments = available_parliaments
    @years = available_years
    @legislatures = available_legislatures
  rescue StandardError => e
    Rails.logger.error("Parliamentary index error: #{e.message}")
    @documents = []
    @total_count = 0
    @total_pages = 0
    @parliaments = []
    @years = Date.current.year.downto(2010).to_a
    @db_unavailable = true
  end

  # GET /parlement/:id
  def show
    doc = chamber_db.execute(
      'SELECT id, parliament, dossier_number, document_number, title, content, url, legislation_numac, legislature, document_type, document_date, language, pdf_url FROM documents WHERE id = ?',
      [params[:id]]
    ).first

    if doc
      preferred_lang = I18n.locale == :nl ? 'nl' : 'fr'
      doc_lang = doc[11]

      # If document language doesn't match user locale, try to find same doc in preferred language
      if doc_lang.present? && doc_lang != preferred_lang
        alt = chamber_db.execute(
          'SELECT id FROM documents WHERE parliament = ? AND legislature = ? AND dossier_number = ? AND document_number = ? AND language = ? LIMIT 1',
          [doc[1], doc[8], doc[2], doc[3], preferred_lang]
        ).first
        if alt
          redirect_to parliamentary_path(alt[0]), status: :found, allow_other_host: false
          return
        end
      end

      @document = {
        id: doc[0],
        parliament: doc[1],
        dossier_number: doc[2],
        document_number: doc[3],
        title: doc[4],
        content: doc[5],
        url: doc[6],
        legislation_numac: doc[7],
        legislature: doc[8],
        document_type: doc[9],
        document_date: doc[10],
        language: doc[11],
        pdf_url: doc[12]
      }
      @title = "#{@document[:parliament]} - #{@document[:document_number]}"

      # Fetch all sibling documents in the same dossier for navigation
      @siblings = chamber_db.execute(
        'SELECT id, document_number, document_type, substr(title,1,120) FROM documents WHERE parliament = ? AND legislature = ? AND dossier_number = ? AND language = ? ORDER BY document_number',
        [@document[:parliament], @document[:legislature], @document[:dossier_number], @document[:language]]
      ).map do |row|
        { id: row[0], document_number: row[1], document_type: row[2], title: row[3] }
      end

      # Fetch enriched dossier metadata from the dossiers table (scraped from dekamer.be fiche)
      if @document[:legislature].present? && @document[:dossier_number].present?
        dossier_num = @document[:dossier_number].to_s.gsub(/\D/, '').to_i
        dossier_row = chamber_db.execute(
          'SELECT status, commission, auteurs, eurovoc_tags, filing_date, vote_result, vote_date, type, rapporteurs, grondwet_artikel, dossier_url FROM dossiers WHERE legislature = ? AND nummer = ?',
          [@document[:legislature], dossier_num]
        ).first
        if dossier_row
          @dossier_meta = {
            status: dossier_row[0],
            commission: dossier_row[1],
            auteurs: dossier_row[2],
            eurovoc_tags: dossier_row[3],
            filing_date: dossier_row[4],
            vote_result: dossier_row[5],
            vote_date: dossier_row[6],
            type: dossier_row[7],
            rapporteurs: dossier_row[8],
            grondwet_artikel: dossier_row[9],
            fiche_url: dossier_row[10]
          }
        end
      end

      # Look up the related legislation title from the main laws DB
      if @document[:legislation_numac].present?
        lang_id = @document[:language] == 'fr' ? 2 : 1
        law = Legislation.find_by(numac: @document[:legislation_numac], language_id: lang_id)
        law ||= Legislation.find_by(numac: @document[:legislation_numac]) # fallback to any language
        @related_law = { numac: law.numac, title: law.title } if law
      end

      # Load roll-call vote details (naamstemmingen) for this dossier
      load_vote_details(db_handle: chamber_db)
    else
      render plain: 'Document not found', status: :not_found
    end
  rescue StandardError => e
    Rails.logger.error("Parliamentary show error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    server_error(e)
  end

  # GET /mps
  def mps
    @title = case I18n.locale when :fr then 'Députés' when :de then 'Abgeordnete' when :en then 'Members of Parliament' else 'Kamerleden' end
    @legislature = (params[:legislature].presence || 56).to_i
    @party_filter = params[:party].presence
    @name_filter = params[:q].presence

    db = chamber_db

    # Fetch all MPs for the legislature
    sql = 'SELECT id, name, party, dekamer_key, kieskring, language, photo_url FROM mps WHERE legislature = ?'
    bind = [@legislature]

    if @party_filter.present?
      sql += ' AND party = ?'
      bind << @party_filter
    end

    if @name_filter.present?
      sql += ' AND name LIKE ?'
      sanitized = @name_filter.gsub('%', '\%').gsub('_', '\_')
      bind << "%#{sanitized}%"
    end

    sql += ' ORDER BY name ASC'

    @members = db.execute(sql, bind).map do |row|
      { id: row[0], name: row[1], party: row[2], dekamer_key: row[3],
        kieskring: row[4], language: row[5], photo_url: row[6] }
    end

    # Enrich with election data (list position, vote count) from elections DB
    enrich_with_election_data(@members, @legislature)

    # Sort by party (spectrum order), then by list_position within party
    spectrum = { 'PVDA-PTB' => 0, 'PVDA' => 0, 'PTB' => 0,
                 'Ecolo' => 1, 'Groen' => 2, 'PS' => 3, 'Vooruit' => 4, 'sp.a' => 4,
                 'cdH' => 5, 'Les Engagés' => 5, 'LE' => 5,
                 'CD&V' => 6, 'cd&v' => 6, 'Open Vld' => 7, 'MR' => 8, 'DéFI' => 9,
                 'N-VA' => 10, 'VB' => 11, 'Anders' => 12 }
    @members.sort_by! { |m| [spectrum[m[:party]] || 99, m[:list_position] || 9999, m[:name]] }

    # Available parties for filter dropdown
    @parties = db.execute(
      'SELECT DISTINCT party FROM mps WHERE legislature = ? AND party IS NOT NULL ORDER BY party',
      [@legislature]
    ).map(&:first).compact

    # Available legislatures
    @legislatures = db.execute(
      'SELECT DISTINCT legislature FROM mps ORDER BY legislature DESC'
    ).map(&:first)

    # Hemicycle data
    @hemicycle_data = helpers.hemicycle_party_data(@legislature)
  rescue StandardError => e
    Rails.logger.error("MP directory error: #{e.message}")
    @members = []
    @parties = []
    @legislatures = [56, 55, 54]
    @hemicycle_data = []
  end

  # GET /mps/hemicycle
  def hemicycle_history
    @title = case I18n.locale when :fr then 'Hémicycle historique' when :de then 'Historischer Plenarsaal' when :en then 'Historical Hemicycle' else 'Historisch Hemicyclus' end

    edb = elections_db
    unless edb
      @years = []
      @hemicycle = nil
      @timeline = []
      return
    end

    # Available years
    @years = edb.execute(
      'SELECT year FROM hemicycle_history WHERE total_seats > 0 ORDER BY year DESC'
    ).map(&:first)

    @selected_year = (params[:year].presence || @years.first).to_i

    # Fetch hemicycle data for the selected year
    row = edb.execute(
      'SELECT year, total_seats, party_data FROM hemicycle_history WHERE year = ?',
      [@selected_year]
    ).first

    if row
      party_data = JSON.parse(row[2])
      @hemicycle = {
        year: row[0],
        total_seats: row[1],
        parties: party_data.map do |party_name, seats|
          spectrum = edb.execute(
            'SELECT spectrum_position, color, family FROM party_spectrum WHERE party_name = ?',
            [party_name]
          ).first
          {
            party: party_name,
            seats: seats,
            spectrum: spectrum ? spectrum[0] : 50,
            color: spectrum ? spectrum[1] : '#888888',
            family: spectrum ? spectrum[2] : 'Unknown'
          }
        end.sort_by { |p| p[:spectrum] }
      }
    end

    # Build timeline data for ALL years (for the stacked-bar overview)
    @timeline = @years.reverse.map do |year|
      trow = edb.execute(
        'SELECT party_data, total_seats FROM hemicycle_history WHERE year = ?', [year]
      ).first
      next unless trow

      year_parties = JSON.parse(trow[0])
      year_total = trow[1]
      sorted = year_parties.map do |name, seats|
        spec = edb.execute('SELECT spectrum_position, color FROM party_spectrum WHERE party_name = ?', [name]).first
        { name: name, seats: seats, spectrum: spec ? spec[0] : 50, color: spec ? spec[1] : '#888' }
      end.sort_by { |p| p[:spectrum] }

      { year: year, total: year_total, parties: sorted }
    end.compact
  rescue StandardError => e
    Rails.logger.error("Hemicycle history error: #{e.message}")
    @years = []
    @hemicycle = nil
    @timeline = []
  end

  # GET /mps/:key
  def mp_show
    @legislature = (params[:legislature].presence || 56).to_i
    key = params[:key]

    db = chamber_db
    row = db.execute(
      'SELECT id, name, party, dekamer_key, kieskring, language, photo_url FROM mps WHERE dekamer_key = ? AND legislature = ? LIMIT 1',
      [key, @legislature]
    ).first

    if row
      @member = { id: row[0], name: row[1], party: row[2], dekamer_key: row[3],
                  kieskring: row[4], language: row[5], photo_url: row[6] }
      @title = @member[:name]

      # Enrich with election data from elections DB
      edb = elections_db
      if edb
        erow = edb.execute(
          'SELECT list_position, vote_count, election_constituency, election_party FROM mp_election_data WHERE legislature = ? AND mp_id = ? LIMIT 1',
          [@legislature, @member[:id]]
        ).first
        if erow
          @member[:list_position] = erow[0]
          @member[:vote_count] = erow[1]
          @member[:election_constituency] = erow[2]
          @member[:election_party] = erow[3]
        end
      end

      # Find dossiers authored by this MP (search in auteurs column)
      # Use full name to avoid false positives with common surnames
      mp_name = @member[:name]
      @authored_dossiers = db.execute(
        'SELECT nummer, status, type, auteurs, filing_date, vote_result FROM dossiers WHERE legislature = ? AND auteurs LIKE ? ORDER BY nummer DESC LIMIT 50',
        [@legislature, "%#{mp_name}%"]
      ).map do |d|
        { nummer: d[0], status: d[1], type: d[2], auteurs: d[3], filing_date: d[4], vote_result: d[5] }
      end

      # Load this MP's voting history from mp_votes table
      load_mp_vote_history(db, @member[:id], @legislature)

      # dekamer.be profile URL
      @dekamer_url = "https://www.dekamer.be/kvvcr/showpage.cfm?section=/depute&language=nl&cfm=cvview54.cfm?key=#{key}&lactivity=#{@legislature}"
    else
      render plain: 'Member not found', status: :not_found
    end
  rescue StandardError => e
    Rails.logger.error("MP show error: #{e.message}\n#{e.backtrace&.first(3)&.join("\n")}")
    render plain: 'Error loading profile', status: :internal_server_error
  end

  private

  def chamber_db
    db_path = ENV.fetch('CHAMBER_DB') do
      Rails.root.join('storage', 'chamber.sqlite3').to_s
    end
    @chamber_db ||= SQLite3::Database.new(db_path)
  end

  def elections_db
    db_path = ENV.fetch('ELECTIONS_DB') do
      Rails.root.join('storage', 'elections.sqlite3').to_s
    end
    return nil unless File.exist?(db_path)

    @elections_db ||= SQLite3::Database.new(db_path)
  end

  # Enrich MP hashes with list_position and vote_count from the elections DB
  def enrich_with_election_data(members, legislature)
    edb = elections_db
    return unless edb

    mp_ids = members.map { |m| m[:id] }
    return if mp_ids.empty?

    placeholders = mp_ids.map { '?' }.join(',')
    rows = edb.execute(
      "SELECT mp_id, list_position, vote_count FROM mp_election_data WHERE legislature = ? AND mp_id IN (#{placeholders})",
      [legislature] + mp_ids
    )

    election_lookup = rows.to_h do |row|
      [row[0], { list_position: row[1], vote_count: row[2] }]
    end

    members.each do |m|
      if (edata = election_lookup[m[:id]])
        m[:list_position] = edata[:list_position]
        m[:vote_count] = edata[:vote_count]
      end
    end
  end

  def search_documents(query, filters, limit, offset)
    conditions = []
    params = []

    if query.present?
      # Use FTS5 for fast full-text search
      fts_query = query.gsub(/[^\p{L}\p{N}\s]/, ' ').squish
      conditions << 'documents.id IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?)'
      params << fts_query
    end

    if filters[:parliament].present?
      conditions << 'parliament = ?'
      params << filters[:parliament]
    end

    if filters[:lang].present?
      conditions << 'language = ?'
      params << filters[:lang]
    end

    if filters[:legislature].present?
      conditions << 'legislature = ?'
      params << filters[:legislature].to_i
    end

    if filters[:year].present? && filters[:year].to_s.match?(/^\d{4}$/)
      conditions << 'document_date LIKE ?'
      params << "#{filters[:year]}-%"
    end

    if filters[:numac].present?
      conditions << 'legislation_numac = ?'
      params << filters[:numac]
    end

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''

    sql = "SELECT id, parliament, dossier_number, document_number, title, url, document_date, document_type, substr(content, 1, 300), legislature FROM documents #{where_clause} ORDER BY id DESC LIMIT ? OFFSET ?"
    params += [limit, offset]

    chamber_db.execute(sql, params).map do |row|
      { id: row[0], parliament: row[1], dossier_number: row[2], document_number: row[3], title: row[4], url: row[5], date: row[6],
        document_type: row[7], description: row[8], legislature: row[9] }
    end
  end

  def count_documents(query, filters)
    conditions = []
    params = []

    if query.present?
      fts_query = query.gsub(/[^\p{L}\p{N}\s]/, ' ').squish
      conditions << 'documents.id IN (SELECT rowid FROM documents_fts WHERE documents_fts MATCH ?)'
      params << fts_query
    end

    if filters[:parliament].present?
      conditions << 'parliament = ?'
      params << filters[:parliament]
    end

    if filters[:lang].present?
      conditions << 'language = ?'
      params << filters[:lang]
    end

    if filters[:year].present? && filters[:year].to_s.match?(/^\d{4}$/)
      conditions << 'document_date LIKE ?'
      params << "#{filters[:year]}-%"
    end

    if filters[:numac].present?
      conditions << 'legislation_numac = ?'
      params << filters[:numac]
    end

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''
    chamber_db.execute("SELECT COUNT(*) FROM documents #{where_clause}", params).first[0]
  end

  def recent_documents(limit, offset)
    lang = I18n.locale == :nl ? 'nl' : 'fr'
    order = @sort == 'date_asc' ? 'ASC' : 'DESC'
    chamber_db.execute(
      "SELECT id, parliament, dossier_number, document_number, title, url, document_date, document_type, substr(content, 1, 300), legislature FROM documents WHERE language = ? ORDER BY id #{order} LIMIT ? OFFSET ?",
      [lang, limit, offset]
    ).map do |row|
      { id: row[0], parliament: row[1], dossier_number: row[2], document_number: row[3], title: row[4], url: row[5], date: row[6],
        document_type: row[7], description: row[8], legislature: row[9] }
    end
  end

  def total_documents_count(lang = nil)
    if lang
      chamber_db.execute('SELECT COUNT(*) FROM documents WHERE language = ?', [lang]).first[0]
    else
      chamber_db.execute('SELECT COUNT(*) FROM documents').first[0]
    end
  end

  def available_parliaments
    # Cache for 24h — parliament codes change very rarely
    Rails.cache.fetch('parliamentary_available_parliaments', expires_in: 24.hours) do
      chamber_db.execute('SELECT DISTINCT parliament FROM documents WHERE parliament IS NOT NULL ORDER BY parliament').map(&:first)
    end
  end

  def available_years
    # Extract years from dossier numbers (format like "54K1234" where 54 = legislature)
    Date.current.year.downto(2010).to_a
  end

  def available_legislatures
    Rails.cache.fetch('parliamentary_available_legislatures', expires_in: 24.hours) do
      chamber_db.execute('SELECT DISTINCT legislature FROM documents WHERE legislature IS NOT NULL ORDER BY legislature DESC').map(&:first)
    end
  end

  def enrich_with_dossier_status(documents)
    return if documents.blank?

    # Build lookup: collect unique (legislature, dossier_nummer) pairs from documents
    doc_keys = documents.filter_map do |doc|
      next unless doc[:dossier_number].present?

      num = doc[:dossier_number].to_s.gsub(/\D/, '').to_i
      leg = doc[:legislature] || doc[:dossier_number].to_s[/^(\d+)/, 1]&.to_i
      [leg, num] if leg && num.positive?
    end.uniq

    return if doc_keys.empty?

    # Batch load dossier metadata
    status_map = {}
    doc_keys.each_slice(50) do |keys|
      placeholders = keys.map { '(?, ?)' }.join(', ')
      flat_params = keys.flatten
      rows = chamber_db.execute(
        "SELECT legislature, nummer, status, vote_result FROM dossiers WHERE (legislature, nummer) IN (#{placeholders})",
        flat_params
      )
      rows.each { |r| status_map[[r[0], r[1]]] = { status: r[2], vote_result: r[3] } }
    end

    # Attach status to each document
    documents.each do |doc|
      num = doc[:dossier_number].to_s.gsub(/\D/, '').to_i
      leg = doc[:legislature] || doc[:dossier_number].to_s[/^(\d+)/, 1]&.to_i
      meta = status_map[[leg, num]]
      if meta
        doc[:dossier_status] = meta[:status]
        doc[:dossier_vote_result] = meta[:vote_result]
      end
    end
  end

  # Load roll-call vote details for a dossier (used in show action)
  def load_vote_details(db_handle:)
    @vote_details = []
    return unless @document && @document[:dossier_number].present? && @document[:legislature].present?

    dossier_num = @document[:dossier_number].to_s.gsub(/\D/, '').to_i
    legislature = @document[:legislature].to_i
    return if dossier_num.zero?

    # Find plenary votes linked to this dossier
    votes = db_handle.execute(
      'SELECT id, meeting_id, topic_id, topic_title_nl, topic_title_fr, vote_date, yes_count, no_count, abstention_count, passed FROM plenary_votes WHERE legislature = ? AND dossier_nummer = ? ORDER BY vote_date DESC, meeting_id DESC',
      [legislature, dossier_num]
    )

    votes.each do |v|
      vote_id = v[0]
      title = I18n.locale == :nl ? (v[3].presence || v[4]) : (v[4].presence || v[3])

      # Fetch individual MP votes with MP details
      mp_rows = db_handle.execute(
        'SELECT mv.choice, m.id, m.name, m.party, m.dekamer_key FROM mp_votes mv JOIN mps m ON m.id = mv.mp_id WHERE mv.plenary_vote_id = ? ORDER BY m.party, m.name',
        [vote_id]
      )

      voters = { 'yes' => [], 'no' => [], 'abstention' => [] }
      mp_rows.each do |row|
        voters[row[0]] << { id: row[1], name: row[2], party: row[3], dekamer_key: row[4] }
      end

      # Group by party within each choice
      voters_by_party = {}
      voters.each do |choice, mps|
        voters_by_party[choice] = mps.group_by { |m| m[:party] || 'Onbekend' }
      end

      @vote_details << {
        id: vote_id,
        meeting_id: v[1],
        topic_id: v[2],
        title: title,
        vote_date: v[5],
        yes_count: v[6],
        no_count: v[7],
        abstention_count: v[8],
        passed: v[9],
        voters: voters,
        voters_by_party: voters_by_party
      }
    end
  rescue StandardError => e
    Rails.logger.error("Vote details error: #{e.message}")
    @vote_details = []
  end

  # Load an MP's voting history (used in mp_show action)
  def load_mp_vote_history(db, mp_id, legislature)
    @vote_history = db.execute(
      'SELECT mv.choice, pv.topic_title_nl, pv.topic_title_fr, pv.vote_date, pv.dossier_nummer, pv.passed, pv.yes_count, pv.no_count, pv.abstention_count FROM mp_votes mv JOIN plenary_votes pv ON pv.id = mv.plenary_vote_id WHERE mv.mp_id = ? AND pv.legislature = ? ORDER BY pv.vote_date DESC LIMIT 100',
      [mp_id, legislature]
    ).map do |row|
      title = I18n.locale == :nl ? (row[1].presence || row[2]) : (row[2].presence || row[1])
      {
        choice: row[0],
        title: title,
        vote_date: row[3],
        dossier_nummer: row[4],
        passed: row[5],
        yes_count: row[6],
        no_count: row[7],
        abstention_count: row[8]
      }
    end

    # Compute summary stats
    @vote_stats = {
      total: @vote_history.size,
      yes: @vote_history.count { |v| v[:choice] == 'yes' },
      no: @vote_history.count { |v| v[:choice] == 'no' },
      abstention: @vote_history.count { |v| v[:choice] == 'abstention' }
    }
  rescue StandardError => e
    Rails.logger.error("MP vote history error: #{e.message}")
    @vote_history = []
    @vote_stats = { total: 0, yes: 0, no: 0, abstention: 0 }
  end
end
