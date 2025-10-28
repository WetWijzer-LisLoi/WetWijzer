# frozen_string_literal: true

# Controller for browsing and searching Belgian jurisprudence (court cases)
# Publicly accessible - no account required.
# Individual case pages are noindex to prevent Google indexation.
class JurisprudenceController < ApplicationController
  before_action :set_noindex
  before_action :set_case, only: %i[show export_word export_typst export_odt]

  # GET /jurisprudence
  def index
    @title = case I18n.locale when :fr then 'Jurisprudence' when :de then 'Rechtsprechung' when :en then 'Case law' else 'Rechtspraak' end
    @query = params[:q].to_s.strip
    @court = params[:court].presence
    @year = params[:year].presence
    @date_from = params[:date_from].presence
    @date_to = params[:date_to].presence
    # Support both lang=NL/FR and language_id=1/2 (for consistency with laws & parliamentary work)
    @lang = if params[:language_id].present?
              params[:language_id].to_s == '2' ? 'FR' : 'NL'
            else
              params[:lang].presence || (I18n.locale == :nl ? 'NL' : 'FR')
            end
    @subject = params[:subject].presence
    @sort = params[:sort].presence || 'date_desc'
    @page = [params[:page].to_i, 1].max
    @per_page = (params[:per_page].presence || 50).to_i.clamp(20, 100)

    offset = (@page - 1) * @per_page

    filters = { court: @court, year: @year, date_from: @date_from, date_to: @date_to, subject: @subject }

    # For Turbo Frame requests, run the search and render only results
    # For full-page loads, prepare filter data but skip the query (Turbo Frame will fetch lazily)
    if turbo_frame_request?
      begin
        if @query.present? || filters.values.any?(&:present?)
          @cases, @total_count = search_cases_with_count(@query, filters.merge(lang: @lang), @per_page, offset)
        else
          @cases, @total_count = recent_cases_with_count(@per_page, offset)
        end
      rescue StandardError => e
        Rails.logger.error("Jurisprudence frame search error: #{e.message}")
        @cases = []
        @total_count = 0
      end
      @total_pages = (@total_count.to_f / @per_page).ceil
      render partial: 'jurisprudence/results', layout: false
      return
    end

    # Full page load: just prepare the filters and cached total count
    @cases = []
    @total_count = total_cases_count
    @total_pages = 0
    @courts = available_courts
    @grouped_courts = grouped_courts
    @subject_matters = available_subject_matters
  rescue StandardError => e
    Rails.logger.error("Jurisprudence index error: #{e.message}")
    @cases = []
    @total_count = 0
    @total_pages = 0
    @courts = []
    @grouped_courts = {}
    @subject_matters = []
    @db_unavailable = true
  end

  # GET /rechtspraak/:id
  def show
    @title = "#{@case[:court]} - #{@case[:case_number]}"
    @wide_layout = true

    # SEO: Set canonical URL explicitly for case law pages
    @canonical_url = "https://#{request.host}/jurisprudence/#{@case[:case_number]}"

    # Resolve numac codes to law titles for display
    if @case[:laws_referenced].present?
      numacs = @case[:laws_referenced].split(/[;,]\s*/).map(&:strip).reject(&:blank?)
      @referenced_laws = numacs.filter_map do |numac|
        law = Legislation.find_by(numac: numac)
        { numac: numac, title: law&.title&.truncate(80), found: law.present? }
      end
    else
      @referenced_laws = []
    end

    # Load case images if available
    @case_images = load_case_images(@case[:case_number])

    # Check for alternate language version (NL↔FR)
    @alt_lang_id = @case[:language_id].to_s == '1' ? 2 : 1
    @alt_lang_label = @alt_lang_id == 2 ? 'FR' : 'NL'
    @alt_case = find_alternate_language_case(@case[:case_number], @alt_lang_id)
  end

  # GET /jurisprudence/:ecli/image/:filename - serve extracted PDF images
  def case_image
    ecli = params[:ecli]
    filename = params[:filename]

    # Sanitize filename to prevent directory traversal
    return head(:bad_request) unless filename.match?(/\A[a-zA-Z0-9_]+\.[a-z]{3,4}\z/)

    # Sanitize ecli: replace colons then strip any non-safe characters (prevents ../ traversal)
    ecli_dir = ecli.tr(':', '_').gsub(/[^a-zA-Z0-9_.-]/, '')
    return head(:bad_request) if ecli_dir.blank? || ecli_dir.include?('..')

    image_dir = ENV.fetch('JURISPRUDENCE_IMAGES_DIR', '/mnt/HC_Volume_104299669/jurisprudence_images')
    filepath = File.join(image_dir, ecli_dir, filename)

    # Final guard: ensure resolved path stays within the image directory
    return head(:bad_request) unless File.expand_path(filepath).start_with?(File.expand_path(image_dir))

    if File.exist?(filepath)
      mime = case File.extname(filename).downcase
             when '.jpg', '.jpeg' then 'image/jpeg'
             when '.png' then 'image/png'
             else 'application/octet-stream'
             end
      send_file filepath, type: mime, disposition: 'inline',
                          filename: "#{ecli_dir}_#{filename}"
    else
      head :not_found
    end
  end

  # GET /jurisprudence/:ecli/export_word
  # Generates a Word (.doc) download of the case text
  def export_word
    unless @case[:full_text].present?
      redirect_to jurisprudence_path(@case[:case_number]), alert: t('laws.no_articles_to_export', default: 'Geen tekst beschikbaar om te exporteren.')
      return
    end

    Rails.logger.info("[EXPORT] Jurisprudence Word export: #{@case[:case_number]} by #{request.remote_ip}")

    court = @case[:court].to_s
    date = @case[:decision_date].to_s
    ecli = @case[:case_number].to_s
    case_text = @case[:full_text].to_s
    rich_text = @case[:rich_text].to_s

    # Use rich_text (HTML) if available, otherwise format plain text
    if rich_text.present? && rich_text.length > 50
      body_html = helpers.sanitize(rich_text, tags: %w[p br em strong b i u a ul ol li table tr td th thead tbody h1 h2 h3 h4 h5 h6 div span sup sub blockquote hr], attributes: %w[href title class style])
    else
      body_html = ERB::Util.html_escape(case_text).gsub("\n\n", "</p>\n<p>").gsub("\n", "<br>\n")
      body_html = "<p>#{body_html}</p>"
    end

    subject = @case[:subject_matter].to_s.presence
    outcome = @case[:outcome].to_s.presence

    html_content = <<~HTML
      <html xmlns:o="urn:schemas-microsoft-com:office:office"
            xmlns:w="urn:schemas-microsoft-com:office:word"
            xmlns="http://www.w3.org/TR/REC-html40">
      <head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <title>#{ERB::Util.html_escape(ecli)}</title>
        <!--[if gte mso 9]>
        <xml>
          <w:WordDocument>
            <w:View>Print</w:View>
            <w:Zoom>100</w:Zoom>
          </w:WordDocument>
        </xml>
        <![endif]-->
        <style>
          body { font-family: "Times New Roman", serif; font-size: 11pt; line-height: 1.5; }
          .header { background-color: #f5f5f5; padding: 12pt; margin-bottom: 18pt; border-bottom: 2px solid #333; }
          .header h1 { font-size: 14pt; font-weight: bold; margin: 0 0 6pt 0; }
          .header table { font-size: 10pt; border-collapse: collapse; }
          .header td { padding: 2pt 12pt 2pt 0; vertical-align: top; }
          .header .label { font-weight: bold; color: #555; }
          .body-text { margin-top: 12pt; }
          .body-text p { margin: 6pt 0; }
          .footer { margin-top: 24pt; padding-top: 6pt; border-top: 1px solid #ccc; font-size: 9pt; color: #999; }
        </style>
      </head>
      <body>
        <div class="header">
          <h1>#{ERB::Util.html_escape(ecli)}</h1>
          <table>
            <tr><td class="label">#{case I18n.locale when :fr then 'Juridiction' when :de then 'Gericht' when :en then 'Court' else 'Rechtsinstantie' end}:</td><td>#{ERB::Util.html_escape(court)}</td></tr>
            <tr><td class="label">#{case I18n.locale when :fr, :en then 'Date' else 'Datum' end}:</td><td>#{ERB::Util.html_escape(date)}</td></tr>
            #{"<tr><td class=\"label\">#{case I18n.locale when :fr then 'Domaine' when :de then 'Rechtsgebiet' when :en then 'Subject' else 'Rechtsdomein' end}:</td><td>#{ERB::Util.html_escape(subject)}</td></tr>" if subject}
            #{"<tr><td class=\"label\">#{case I18n.locale when :fr then 'Décision' when :de then 'Urteil' when :en then 'Ruling' else 'Uitspraak' end}:</td><td>#{ERB::Util.html_escape(outcome)}</td></tr>" if outcome}
          </table>
        </div>
        <div class="body-text">
          #{body_html}
        </div>
        <div class="footer">
          <p>#{case I18n.locale when :fr then 'Consulté le' when :de then 'Abgerufen am' when :en then 'Accessed on' else 'Geraadpleegd op' end}: #{Date.today.strftime('%d/%m/%Y')} - WetWijzer.be</p>
          <p>#{(case I18n.locale when :fr then 'Texte pseudonymisé (RGPD)' when :de then 'Pseudonymisierter Text (DSGVO)' when :en then 'Pseudonymised text (GDPR)' else 'Gepseudonimiseerde tekst (GDPR)' end) if @pseudonymized}</p>
        </div>
      </body>
      </html>
    HTML

    court_short = court.gsub(/[^a-zA-Z0-9]/, '_').truncate(30, omission: '')
    date_short = date.gsub('-', '')
    filename = "#{court_short}_#{date_short}.doc"

    send_data html_content,
              filename: filename,
              type: 'application/msword',
              disposition: 'attachment'
  end

  # GET /jurisprudence/:ecli/export_typst
  # Generates a Typst (.typ) download of the case text
  def export_typst
    unless @case[:full_text].present?
      redirect_to jurisprudence_path(@case[:case_number]), alert: t('laws.no_articles_to_export', default: 'Geen tekst beschikbaar om te exporteren.')
      return
    end

    Rails.logger.info("[EXPORT] Jurisprudence Typst export: #{@case[:case_number]} by #{request.remote_ip}")

    # Use rich_text stripped to plain, or plain text directly
    rich_text = @case[:rich_text].to_s.strip
    case_text = @case[:full_text].to_s
    body_text = if rich_text.present? && rich_text.length > 50
                  ActionController::Base.helpers.strip_tags(rich_text)
                else
                  case_text
                end

    typst_content = TypstGenerator.jurisprudence_document(
      case_data: @case,
      body_text: body_text,
      locale: I18n.locale,
      pseudonymized: @pseudonymized
    )

    court_short = @case[:court].to_s.gsub(/[^a-zA-Z0-9]/, '_').truncate(30, omission: '')
    date_short = @case[:decision_date].to_s.gsub('-', '')
    filename = "#{court_short}_#{date_short}.typ"

    send_data typst_content,
              filename: filename,
              type: 'text/plain; charset=utf-8',
              disposition: 'attachment'
  end

  # GET /jurisprudence/:ecli/export_odt
  # Generates an ODT (.odt) download of the case text
  def export_odt
    unless @case[:full_text].present?
      redirect_to jurisprudence_path(@case[:case_number]), alert: t('laws.no_articles_to_export', default: 'Geen tekst beschikbaar om te exporteren.')
      return
    end

    Rails.logger.info("[EXPORT] Jurisprudence ODT export: #{@case[:case_number]} by #{request.remote_ip}")

    # Use rich_text stripped to plain, or plain text directly
    rich_text = @case[:rich_text].to_s.strip
    case_text = @case[:full_text].to_s
    body_text = if rich_text.present? && rich_text.length > 50
                  ActionController::Base.helpers.strip_tags(rich_text)
                else
                  case_text
                end

    odt_content = OdtGenerator.jurisprudence_document(
      case_data: @case,
      body_text: body_text,
      locale: I18n.locale,
      pseudonymized: @pseudonymized
    )

    court_short = @case[:court].to_s.gsub(/[^a-zA-Z0-9]/, '_').truncate(30, omission: '')
    date_short = @case[:decision_date].to_s.gsub('-', '')
    filename = "#{court_short}_#{date_short}.odt"

    send_data odt_content,
              filename: filename,
              type: 'application/vnd.oasis.opendocument.text',
              disposition: 'attachment'
  end

  private

  # Set noindex meta tag for all jurisprudence pages (GDPR: prevent search engine indexation)
  def set_noindex
    @noindex = true
  end

  def set_case
    db = jurisprudence_db
    ecli = params[:ecli]

    # Backward compatibility: if someone visits /jurisprudence/12345 (old numeric ID),
    # look up the ECLI and redirect permanently
    if ecli =~ /\A\d+\z/
      row = db.execute('SELECT case_number FROM cases WHERE id = ?', [ecli.to_i]).first
      if row
        redirect_to jurisprudence_path(row[0]), status: :moved_permanently
        return
      else
        render plain: 'Case not found', status: :not_found
        return
      end
    end

    # GDPR: Prefer pseudonymized_text over full_text to avoid exposing personal data.
    # Graceful fallback: if pseudonymized_text column doesn't exist yet, use full_text.
    has_pseudo = db.execute('PRAGMA table_info(cases)').any? { |col| col[1] == 'pseudonymized_text' }
    text_col = has_pseudo ? 'COALESCE(pseudonymized_text, full_text)' : 'full_text'

    row = db.execute(
      "SELECT id, case_number, court, decision_date, summary, #{text_col}, url, language_id, subject_matter, decision_type, outcome, laws_referenced, rich_text FROM cases WHERE case_number = ?",
      [ecli]
    ).first

    if row
      @case = {
        id: row[0],
        case_number: row[1],
        court: row[2],
        decision_date: row[3],
        summary: row[4],
        full_text: row[5], # Actually pseudonymized_text when available
        url: row[6],
        language_id: row[7],
        subject_matter: row[8],
        decision_type: row[9],
        outcome: row[10],
        laws_referenced: row[11],
        rich_text: row[12]
      }
      @pseudonymized = has_pseudo
    else
      render plain: 'Case not found', status: :not_found
    end
  rescue StandardError => e
    Rails.logger.error("Jurisprudence set_case error: #{e.message}")
    render plain: 'Case not found', status: :not_found
  end

  def jurisprudence_db
    db_path = ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
      Rails.root.join('storage', 'jurisprudence.db').to_s
    end
    @jurisprudence_db ||= SQLite3::Database.new(db_path)
  end

  # Load extracted PDF images for a case from the case_images table
  def load_case_images(case_number)
    db = jurisprudence_db
    rows = db.execute(
      'SELECT page_number, image_index, filename, mime_type, width, height FROM case_images WHERE case_number = ? AND filename != ? ORDER BY page_number, image_index',
      [case_number, '__no_images__']
    )
    rows.map do |row|
      { page: row[0], index: row[1], filename: row[2], mime: row[3], width: row[4], height: row[5] }
    end
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] Query failed: #{e.message}")
    [] # Table may not exist yet
  end

  # Find alternate language version of a case.
  # Belgian courts often publish decisions in both NL and FR.
  # We match by court + decision_date + different language_id.
  def find_alternate_language_case(case_number, alt_lang_id)
    db = jurisprudence_db
    # First: try exact match by court + date (most reliable)
    current = db.execute(
      'SELECT court, decision_date FROM cases WHERE case_number = ?', [case_number]
    ).first
    return nil unless current

    court, date = current
    row = db.execute(
      'SELECT case_number FROM cases WHERE court = ? AND decision_date = ? AND language_id = ? AND case_number != ? LIMIT 1',
      [court, date, alt_lang_id, case_number]
    ).first
    row ? row[0] : nil
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] Query failed: #{e.message}")
    nil
  end

  # Combined search + count using window function - eliminates separate COUNT query
  def search_cases_with_count(query, filters, limit, offset)
    conditions = []
    params = []

    # Exclude ADB (Arrestendatabank) legacy entries - they have no text and cause errors
    conditions << "case_number NOT LIKE 'ADB:%'"

    if query.present?
      fts_query = query.gsub(/[^\p{L}\p{N}\s]/, ' ').squish
      if fts_available?
        # Use FTS5 for fast full-text search
        conditions << 'cases.id IN (SELECT rowid FROM cases_fts WHERE cases_fts MATCH ?)'
        params << fts_query
      else
        # Fallback: LIKE-based search (slower but works without FTS5 table)
        like_terms = fts_query.split.map { |t| "%#{t}%" }
        like_terms.each do |term|
          conditions << '(summary LIKE ? OR case_number LIKE ? OR court LIKE ? OR subject_matter LIKE ?)'
          params.push(term, term, term, term)
        end
      end
    end

    build_filter_conditions(filters, conditions, params)

    where_clause = conditions.any? ? "WHERE #{conditions.join(' AND ')}" : ''

    order = @sort == 'date_asc' ? 'ASC' : 'DESC'
    # Window function COUNT(*) OVER() returns total count in each row - no separate count query needed
    sql = "SELECT id, case_number, court, decision_date, summary, language_id, subject_matter, appellant, COUNT(*) OVER() as total_count FROM cases #{where_clause} ORDER BY decision_date #{order} LIMIT ? OFFSET ?"
    params += [limit, offset]

    rows = jurisprudence_db.execute(sql, params)
    total = rows.first ? rows.first[8] : 0
    cases = rows.map do |row|
      { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], language_id: row[5],
        subject_matter: row[6], appellant: row[7] }
    end
    [cases, total]
  end

  def build_filter_conditions(filters, conditions, params)
    if filters[:court].present?
      court_pattern = court_pattern_for(filters[:court])
      conditions << 'court LIKE ?'
      params << court_pattern
    end

    if filters[:year].present?
      conditions << 'decision_date LIKE ?'
      params << "#{filters[:year]}-%"
    end

    if filters[:date_from].present?
      conditions << 'decision_date >= ?'
      params << filters[:date_from]
    end

    if filters[:date_to].present?
      conditions << 'decision_date <= ?'
      params << filters[:date_to]
    end

    if filters[:lang].present?
      # language_id: 1=NL, 2=FR (see languages table)
      conditions << 'language_id = ?'
      params << (filters[:lang].upcase == 'NL' ? '1' : '2')
    end

    return unless filters[:subject].present?

    conditions << 'subject_matter LIKE ?'
    params << "%#{filters[:subject]}%"
  end

  # Combined recent cases + count using window function
  def recent_cases_with_count(limit, offset)
    order = @sort == 'date_asc' ? 'ASC' : 'DESC'
    # language_id: 1=NL, 2=FR (see languages table)
    lang_id = @lang.to_s.upcase == 'NL' ? '1' : '2'
    rows = jurisprudence_db.execute(
      "SELECT id, case_number, court, decision_date, summary, language_id, subject_matter, appellant, COUNT(*) OVER() as total_count FROM cases WHERE language_id = ? AND case_number NOT LIKE 'ADB:%' ORDER BY decision_date #{order} LIMIT ? OFFSET ?",
      [lang_id, limit, offset]
    )
    total = rows.first ? rows.first[8] : 0
    cases = rows.map do |row|
      { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], language_id: row[5],
        subject_matter: row[6], appellant: row[7] }
    end
    [cases, total]
  end

  def fts_available?
    Rails.cache.fetch('jurisprudence_fts_available', expires_in: 10.minutes) do
      jurisprudence_db.execute('SELECT 1 FROM cases_fts LIMIT 0')
      true
    rescue StandardError => e
      Rails.logger.warn("[Jurisprudence] FTS check failed: #{e.message}")
      false
    end
  end

  def total_cases_count
    Rails.cache.fetch('jurisprudence_total_count', expires_in: 1.hour) do
      jurisprudence_db.execute('SELECT COUNT(*) FROM cases').first[0]
    end
  end

  def available_courts
    # Cache for 24h - courts only change when new jurisprudence is imported
    Rails.cache.fetch('jurisprudence_available_courts', expires_in: 24.hours) do
      raw_courts = jurisprudence_db.execute("SELECT DISTINCT court FROM cases WHERE court IS NOT NULL AND court != 'Unknown'").map(&:first)
      raw_courts.map { |c| normalize_court(c) }.compact.uniq.sort
    end
  end

  def available_subject_matters
    # Subject matter translations
    translations = {
      'arbeidsrecht' => { nl: 'Arbeidsrecht', fr: 'Droit du travail' },
      'bestuursrecht' => { nl: 'Bestuursrecht', fr: 'Droit administratif' },
      'burgerlijk_recht' => { nl: 'Burgerlijk recht', fr: 'Droit civil' },
      'fiscaal_recht' => { nl: 'Fiscaal recht', fr: 'Droit fiscal' },
      'grondwettelijk' => { nl: 'Grondwettelijk recht', fr: 'Droit constitutionnel' },
      'sociaal_recht' => { nl: 'Sociaal recht', fr: 'Droit social' },
      'strafrecht' => { nl: 'Strafrecht', fr: 'Droit pénal' },
      'vennootschapsrecht' => { nl: 'Vennootschapsrecht', fr: 'Droit des sociétés' }
    }

    locale = case I18n.locale when :nl, :de then :nl else :fr end
    translations.map { |key, labels| [labels[locale], key] }.sort_by(&:first)
  end

  # Get courts grouped by hierarchy level for the filter dropdown
  def grouped_courts
    locale = I18n.locale
    raw_courts = available_courts

    # Map normalized court names to BelgianCourtService keys
    court_mapping = {
      'Grondwettelijk Hof' => :grondwettelijk_hof,
      'Hof van Cassatie' => :hof_van_cassatie,
      'Raad van State' => :raad_van_state,
      'Hof van Beroep' => :hof_van_beroep,
      'Arbeidshof' => :arbeidshof,
      'Hof van Assisen' => :hof_van_assisen,
      'Rechtbank eerste aanleg' => :rechtbank_eerste_aanleg,
      'Arbeidsrechtbank' => :arbeidsrechtbank,
      'Ondernemingsrechtbank' => :ondernemingsrechtbank,
      'Beslagrechter' => :beslagrechter,
      'Handhavingscollege' => :handhavingscollege
    }

    # Group available courts by level
    grouped = { 1 => [], 2 => [], 3 => [], 4 => [] }
    other_courts = []

    raw_courts.each do |court_name|
      key = court_mapping[court_name]
      if key && (info = BelgianCourtService.court_info(key))
        level = info[:level]
        display_name = locale == :nl ? info[:name_nl] : info[:name_fr]
        grouped[level] << [display_name, court_name]
      else
        other_courts << [court_name, court_name]
      end
    end

    # Build result with level labels
    result = {}
    [1, 2, 3, 4].each do |level|
      next if grouped[level].empty?

      label = BelgianCourtService.level_label(level, locale)
      result[label] = grouped[level].sort_by(&:first)
    end

    # Add other courts if any
    if other_courts.any?
      result[case I18n.locale when :fr then 'Autres' when :de then 'Sonstige' when :en then 'Other' else 'Overige' end] = other_courts.sort_by(&:first)
    end

    result
  end

  def court_pattern_for(category)
    # Return SQL LIKE pattern for court category
    case category
    when 'Grondwettelijk Hof'
      '%Grondwettelijk Hof%'
    when 'Hof van Cassatie'
      '%Hof van Cassatie%'
    when 'Raad van State'
      '%Raad van State%'
    when 'Hof van Beroep'
      '%Hof van Beroep%'
    when 'Arbeidshof'
      '%Arbeidshof%'
    when 'Arbeidsrechtbank'
      '%Arbeidsrechtbank%'
    when 'Ondernemingsrechtbank'
      '%Ondernemingsrechtbank%'
    when 'Rechtbank eerste aanleg'
      '%Rechtbank eerste aanleg%'
    when 'Beslagrechter'
      '%Beslagrechter%'
    when 'Handhavingscollege'
      '%Handhavingscollege%'
    else
      "%#{category}%"
    end
  end

  def normalize_court(court)
    return nil if court.blank? || court == 'Unknown'

    case court
    when /Grondwettelijk Hof|Cour Constitutionnelle/i
      'Grondwettelijk Hof'
    when /Hof van Cassatie|Cour de Cassation/i
      'Hof van Cassatie'
    when /Raad van State|Conseil d'État/i
      'Raad van State'
    when /Hof van Beroep|Cour d'appel/i
      'Hof van Beroep'
    when /Arbeidshof|Cour du travail/i
      'Arbeidshof'
    when /Arbeidsrechtbank|Tribunal du travail/i
      'Arbeidsrechtbank'
    when /Ondernemingsrechtbank|Tribunal de l'entreprise/i
      'Ondernemingsrechtbank'
    when /Rechtbank eerste aanleg|Tribunal de première instance/i
      'Rechtbank eerste aanleg'
    when /Beslagrechter|Juge des saisies/i
      'Beslagrechter'
    when /Handhavingscollege/i
      'Handhavingscollege'
    else
      court # Keep original if no match
    end
  end
end
