# frozen_string_literal: true

# Controller for browsing and searching Belgian jurisprudence (court cases)
# Publicly accessible - no account required.
# Individual case pages are noindex to prevent Google indexation.
class JurisprudenceController < ApplicationController
  before_action :set_noindex
  before_action :set_case, only: %i[show export_word export_typst export_odt]
  # Declared after set_case on purpose: set_case renders the 404 itself, which
  # halts the chain, so this one only ever sees a case that exists.
  before_action :apply_requested_language, only: %i[show export_word export_typst export_odt]

  # An advisory opinion's key suffix is how the Council FILED the document, and
  # it finds the counterpart exactly: measured on production 2026-09-17, all
  # 58,626 RVSADV keys fit this shape and 10,114 pairs share a stem. It does NOT
  # say what language the stored text is in. Many opinions are stored whole and
  # bilingual, and language_id disagrees with the suffix on 5,938 of 27,297 :FR
  # keys; of 3,000 of those sampled for function words of both languages, 1,837
  # held both, 940 held Dutch only and 13 French only. So the suffix is used to
  # find and to name the sibling, and the badge follows language_id, as it did
  # before the toggle was rebuilt.
  ADVISORY_KEY = /\A(RVSADV:[\d.]+):(NL|FR)\z/
  # 1 NL, 2 FR, 3 DE. Production holds only 1 (160,389 rows) and 2 (111,723)
  # today; 3 is admitted because case_documents allows it.
  CASE_LANGUAGE_IDS = [1, 2, 3].freeze
  # The language_id values the listing and the search ask for, by the language
  # the listing is in (?lang= or ?language_id=, else the site's own).
  #
  # Both paths used to ask for 1 or 2 and nothing else, so a judgment stored as
  # 3 kept its page and dropped out of every listing and search on every site:
  # the 30 Council judgments that open with the German masthead STAATSRAT
  # (docs/ops/open-items.md, "Merge the sweep documents and language facts")
  # would have vanished the moment they were relabelled. The German site has
  # no case law of its own and, like current_language_id, falls back to
  # French, so it lists German and French together; the Dutch and French
  # sites keep their own language. Anything unrecognised is French, as the
  # old ternary made it.
  LISTING_LANGUAGE_IDS = { 'NL' => [1], 'FR' => [2], 'DE' => [3, 2] }.freeze
  # `status` is REQUIRED so that a case_documents table without it is ignored
  # rather than served: the text is rendered and exported verbatim, and the
  # status filter is the only thing between an unreviewed document and the page.
  CASE_DOCUMENT_REQUIRED = %w[case_number language_id full_text status].freeze
  # Only what the page reads. The contract's pdf_url and source are left in the
  # table: the Council's PDF link is rebuilt from `url` by raadvst_source_url,
  # and JuPortal's PDF stays the stored row's.
  CASE_DOCUMENT_OPTIONAL = %w[summary url role].freeze
  CASE_DOCUMENT_PUBLIC_STATUS = 'published'
  # "Has text", asked in these words by both readers of the table, so the
  # toggle cannot offer what the page then declines. They had a definition
  # each: the toggle, which never loads the text, trimmed tab, LF, CR and space
  # in SQL, and the page asked blank? in Ruby, which also strips form feed,
  # vertical tab and NBSP. A document of form feeds alone (all pdftotext gives
  # for a scanned PDF) got a live pill that rendered the stored text. The set
  # is ASCII whitespace plus NBSP (160); NULL fails the comparison too.
  CASE_DOCUMENT_HAS_TEXT = "trim(full_text, char(9, 10, 11, 12, 13, 32, 160)) != ''"

  # GET /jurisprudence
  # The default listing goes this many rows back; further pages ask for a
  # search or a filter (every page of it walks the decision-date index to
  # its offset).
  MAX_RECENT_OFFSET = 5_000
  LISTING_COLUMNS = 'id, case_number, court, decision_date, summary, language_id, subject_matter, appellant'

  # A query without the full-text index: the LIKE fallback that stood in for
  # it scanned every case.
  class SearchUnavailable < StandardError; end

  def index
    @title = case I18n.locale when :fr then 'Jurisprudence' when :de then 'Rechtsprechung' when :en then 'Case law' else 'Rechtspraak' end
    @query = params[:q].to_s.strip
    @court = params[:court].presence
    @year = params[:year].presence
    @date_from = params[:date_from].presence
    @date_to = params[:date_to].presence
    # Support both lang=NL/FR/DE and language_id=1/2/3 (for consistency with
    # laws & parliamentary work). See LISTING_LANGUAGE_IDS for what each lists.
    @lang = if params[:language_id].present?
              { '2' => 'FR', '3' => 'DE' }.fetch(params[:language_id].to_s, 'NL')
            else
              params[:lang].presence || site_listing_language
            end
    @subject = params[:subject].presence
    @sort = params[:sort].presence || 'date_desc'
    @page = [params[:page].to_i, 1].max
    @per_page = (params[:per_page].presence || 50).to_i.clamp(20, 100)

    offset = (@page - 1) * @per_page

    filters = { court: @court, year: @year, date_from: @date_from, date_to: @date_to, subject: @subject }

    # 10:49 no-JS plan, C.2: the full page renders the results itself through
    # the frame's query path, and the frame keeps answering Turbo's enhanced
    # navigation. A full page used to hold only a lazy frame, so without
    # scripts no decision was ever listed.
    load_results(filters, offset)
    if turbo_frame_request?
      render partial: 'jurisprudence/results', layout: false
      return
    end

    @corpus_count = total_cases_count
    @courts = available_courts
    @grouped_courts = grouped_courts
    @subject_matters = available_subject_matters
  rescue StandardError => e
    Rails.logger.error("Jurisprudence index error: #{e.message}")
    @cases = []
    @corpus_count = 0
    @total_count = nil
    @total_pages = 0
    @courts = []
    @grouped_courts = {}
    @subject_matters = []
    @db_unavailable = true
    @search_failed = true
  end

  # GET /rechtspraak/:id
  def show
    @title = "#{@case[:court]} - #{@case[:case_number]}"
    @wide_layout = true

    # SEO: Set canonical URL explicitly for case law pages. A second-language
    # document is a page of its own, as laws_controller makes it for
    # ?language_id=; the stored text stays on the bare URL. Unlike the
    # legislation pages nothing here redirects to add the parameter: bare
    # /jurisprudence/<key> links are minted by the chatbot, by
    # legislation.jurisprudence_refs and by the popular-laws partial.
    @canonical_url = "https://#{request.host}/jurisprudence/#{@case[:case_number]}"
    @canonical_url += "?language_id=#{@page_language_id}" if @showing_alternate

    # Resolve numac codes to law titles for display
    if @case[:laws_referenced].present?
      numacs = @case[:laws_referenced].split(/[;,]\s*/).map(&:strip).reject(&:blank?)
      @referenced_laws = numacs.filter_map do |numac|
        law = Legislation.in_site_languages.find_by(numac: numac)
        { numac: numac, title: law&.title&.truncate(80), found: law.present? }
      end
    else
      @referenced_laws = []
    end

    # Load case images if available
    @case_images = load_case_images(@case[:case_number])

    # The languages this decision can be read in, for the toggle.
    @language_versions = language_versions_for(@primary_case, @page_language_id)

    # The parliamentary documents that print or cite an advisory opinion, as
    # the weekly link job found them (OpinionParliamentLinks); [] for a
    # judgment, for an opinion nobody cites, and while the link file is absent.
    @parliamentary_documents = OpinionParliamentLinks.documents_for(
      @case[:case_number], language: I18n.locale == :fr ? 'fr' : 'nl'
    )
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

    # Only while the decision itself is published. A withdrawal deletes the
    # row from `cases` and nothing else, and the directory and file names are
    # guessable (ECLI_BE_RVSCE_2000_ARR.90.727/p11_0.png): without this the
    # images of a withdrawn decision, extracted from a PDF that may carry the
    # very names the withdrawal took down, stayed one URL away.
    return head(:not_found) unless published_case?(ecli)

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
      redirect_to jurisprudence_path(@case[:case_number]), alert: t('jurisprudence.no_text_to_export')
      return
    end

    SecurityLog.info('case_export', request: request, format: 'word', ecli: @case[:case_number])

    court = @case[:court].to_s
    date = @case[:decision_date].to_s
    ecli = @case[:case_number].to_s
    case_text = @case[:full_text].to_s

    # full_text only: rich_text was an unpseudonymized April 2026 copy (and
    # despite its name held no markup at all). See show.html.erb.
    body_html = ERB::Util.html_escape(case_text).gsub("\n\n", "</p>\n<p>").gsub("\n", "<br>\n")
    body_html = "<p>#{body_html}</p>"

    subject = @case[:subject_matter].to_s.presence
    # An advice says what it is (WW-RVSADV-01): no judgment, no rule in force.
    kind = @case[:decision_type].to_s.presence if @case[:case_number].to_s.start_with?('RVSADV:')
    type_label = case I18n.locale when :fr then 'Type de document' when :de then 'Dokumentart' when :en then 'Document type' else 'Documentsoort' end
    kind_row = kind ? %(<tr><td class="label">#{type_label}:</td><td>#{ERB::Util.html_escape(kind)}</td></tr>) : ''
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
            #{kind_row}
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
      redirect_to jurisprudence_path(@case[:case_number]), alert: t('jurisprudence.no_text_to_export')
      return
    end

    SecurityLog.info('case_export', request: request, format: 'typst', ecli: @case[:case_number])

    # full_text only - see export_word.
    body_text = @case[:full_text].to_s

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
      redirect_to jurisprudence_path(@case[:case_number]), alert: t('jurisprudence.no_text_to_export')
      return
    end

    SecurityLog.info('case_export', request: request, format: 'odt', ecli: @case[:case_number])

    # full_text only - see export_word.
    body_text = @case[:full_text].to_s

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
    columns = db.execute('PRAGMA table_info(cases)').map { |col| col[1] }
    has_pseudo = columns.include?('pseudonymized_text')
    text_col = has_pseudo ? 'COALESCE(pseudonymized_text, full_text)' : 'full_text'

    # pdf_url is written by the scraper from the case page it already fetches,
    # and is absent until that scraper has run against this corpus. Selected
    # the same graceful way as pseudonymized_text: NULL here means "nobody has
    # looked yet", which the view distinguishes from a recorded "no scan".
    pdf_col = columns.include?('pdf_url') ? 'pdf_url' : 'NULL'
    # Who sat on the case, as data rather than as a sentence to be read out of
    # the text. Absent until the scraper that records it has run over a corpus.
    bench_col = columns.include?('bench') ? 'bench' : 'NULL'
    # The language the decision was GIVEN in, which language_id (the language of
    # the stored text) cannot say. Absent on production until the sweep loader
    # has run, and NULL afterwards wherever it was not established: the loader
    # gives no fact to 898 of the 104,539 swept numbers (662 of them judgments of
    # the bilingual formations, 114 single versions that are themselves a
    # translation) and only the Council was swept. NULL therefore means
    # "unknown", never "same as the text". A fact once set stays: both corpus
    # writers are UPSERTs that leave the two columns alone.
    orig_col = columns.include?('original_language_id') ? 'original_language_id' : 'NULL'
    orig_source_col = columns.include?('original_language_source') ? 'original_language_source' : 'NULL'

    row = db.execute(
      "SELECT id, case_number, court, decision_date, summary, #{text_col}, url, language_id, " \
      "subject_matter, decision_type, outcome, laws_referenced, #{pdf_col}, #{bench_col}, " \
      "#{orig_col}, #{orig_source_col} " \
      'FROM cases WHERE case_number = ?',
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
        pdf_url: row[12],
        bench: parse_bench(row[13]),
        original_language_id: CASE_LANGUAGE_IDS.include?(row[14].to_i) ? row[14].to_i : nil,
        original_language_source: row[15].presence
      }
      @pseudonymized = has_pseudo
    elsif (sibling = moved_advisory_key(ecli))
      redirect_to moved_advisory_location(sibling), status: :moved_permanently
    else
      render plain: 'Case not found', status: :not_found
    end
  rescue StandardError => e
    Rails.logger.error("Jurisprudence set_case error: #{e.message}")
    render plain: 'Case not found', status: :not_found
  end

  # The other-suffix key of an advisory opinion that is not published under
  # the key asked for, when that other key IS published; nil otherwise.
  #
  # The opinion reload of 2026-09-23 re-keyed documents and deleted the key
  # that went away. Measured on production 2026-09-24 from the key lists: all
  # 1,559 "split-moved" keys of adv4_delete_site_keys.txt now 404 while the
  # same Council number is live under the other suffix, and nothing else, so
  # every link and bookmark to them was dead. The suffix is only how the
  # Council filed the document (see ADVISORY_KEY), so the number alone names
  # it; the missing suffix of any single-row opinion (28,800 of 74,787
  # numbers) leads to it the same way.
  #
  # Narrow on purpose: an RVSADV key of exactly that shape, only the suffix
  # changes, and only to a row of `cases`, the published table. A withdrawal
  # deletes the row from `cases`, so a document withdrawn in both languages
  # has nothing to lead to and stays a 404, and a redirect can only ever lead
  # to a page that its own URL already serves; case_documents is never asked,
  # whatever its status says. A key that exists never gets here.
  #
  # So withdrawing an opinion means withdrawing BOTH suffixes: a withdrawn key
  # whose other suffix is still published answers 301 to that page, not 404.
  def moved_advisory_key(key)
    advisory = ADVISORY_KEY.match(key.to_s)
    return nil unless advisory

    sibling = "#{advisory[1]}:#{advisory[2] == 'NL' ? 'FR' : 'NL'}"
    row = jurisprudence_db.execute('SELECT case_number FROM cases WHERE case_number = ? LIMIT 1', [sibling]).first
    row && row[0]
  end

  # The same action on the sibling's key, as a path on the host that was asked
  # (the site's language is its domain; routes carry no locale prefix), with
  # the query string passed through as it came. Never url_for(params): a
  # ?host= in the query would pick the redirect's host.
  def moved_advisory_location(sibling)
    path = case action_name
           when 'export_word' then export_word_jurisprudence_path(sibling)
           when 'export_typst' then export_typst_jurisprudence_path(sibling)
           when 'export_odt' then export_odt_jurisprudence_path(sibling)
           else jurisprudence_path(sibling)
           end
    request.query_string.present? ? "#{path}?#{request.query_string}" : path
  end

  # [{name, surname, office}] - the members recorded for this case, or [].
  # Stored as JSON by the scraper; a row written before the column existed, or
  # by a source that does not record it, simply has none.
  def parse_bench(value)
    return [] if value.blank?

    parsed = JSON.parse(value)
    return [] unless parsed.is_a?(Array)

    parsed.filter_map do |entry|
      next unless entry.is_a?(Hash) && entry['name'].present?

      { name: entry['name'].to_s, surname: entry['surname'].to_s, office: entry['office'].to_s }
    end
  rescue JSON::ParserError => e
    Rails.logger.warn("[Jurisprudence] unreadable bench: #{e.message}")
    []
  end

  def jurisprudence_db
    @jurisprudence_db_path = ENV.fetch('JURISPRUDENCE_SOURCE_DB') do
      Rails.root.join('storage', 'jurisprudence.db').to_s
    end
    @jurisprudence_db ||= SQLite3::Database.new(@jurisprudence_db_path)
  end

  # Whether `cases` holds this exact key: one point lookup on its unique
  # index. Any error reads as "no", so an image is never served on a guess.
  def published_case?(ecli)
    jurisprudence_db.get_first_value('SELECT 1 FROM cases WHERE case_number = ? LIMIT 1', [ecli.to_s]).present?
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] image lookup failed: #{e.message}")
    false
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

  # The other language of a decision, by two exact lookups and nothing else.
  #
  # What was here before matched "same court, same date, other language_id". Measured
  # on production 2026-09-17 it never fired on a judgment, because a Dutch row
  # says 'Raad van State' and its French one "Conseil d'État" and the match
  # demanded equal court strings (0 hits in three sampled months). It fired only
  # on advisory opinions, a body that issues dozens of documents a day, and
  # there it was wrong every time: 172 links in 2019-03, 0 of them to the true
  # counterpart, 109 picked from more than one candidate, all 46 real pairs
  # missed. And it cost every case page a walk of idx_lang (0.851 s timed for a
  # Council judgment, 0.124 s for a Cassation one), the least selective index on
  # the table. Its replacements are point lookups on unique indexes: 3 to 6 ms
  # timed for the sibling key, sqlite3 start-up included.

  # The language of the text on the page, 1 NL / 2 FR / 3 DE: language_id, for
  # an advisory opinion too (see ADVISORY_KEY for why its suffix is not asked).
  # Anything else falls back to Dutch, as juportal_language does, where the old
  # binary badge said FR; production holds no such row (160,389 rows of 1 and
  # 111,723 of 2, nothing else, 2026-09-17).
  def page_language_id(kase)
    language_id = kase[:language_id].to_i
    CASE_LANGUAGE_IDS.include?(language_id) ? language_id : 1
  end

  # ?language_id=N on a case page means "the published document in that
  # language, on this same page". The document is laid OVER @case rather than
  # beside it, so the view, the three exports and every helper keep reading
  # @case[:full_text] / [:url] unchanged; @primary_case keeps the stored row.
  # The bench, the metadata and the cited laws are the decision's and stay.
  #
  # Anything that cannot be served renders the stored text with a 200, never a
  # 404: unified search and the search adapter already append the row's own
  # language_id to their links, so the parameter is in the wild.
  def apply_requested_language
    @primary_case = @case
    @page_language_id = page_language_id(@case)
    # An opinion's other language is a row of its own, reached by its own key.
    return if ADVISORY_KEY.match?(@case[:case_number].to_s)

    # Matched whole: '2 OR 1=1'.to_i is 2.
    wanted = params[:language_id].to_s
    return unless wanted.match?(/\A[123]\z/)
    return if wanted.to_i == @page_language_id

    document = find_case_document(@case[:case_number], wanted.to_i)
    return unless document

    # summary is the document's own or none: a Dutch summary above a French
    # text is worse than no summary.
    @case = @case.merge(full_text: document[:full_text], summary: document[:summary].presence,
                        url: document[:url], language_id: document[:language_id],
                        document_role: document[:role])
    @page_language_id = document[:language_id]
    @showing_alternate = true
  end

  # One PRAGMA answers both "is the table there" and "which optional columns
  # does it have": table_info of a missing table returns [] and does not raise
  # (sqlite3 gem 2.9.6), where a SELECT against it would. Asked per request,
  # like the cases columns in set_case, so a table created by a loader is
  # picked up without a restart.
  def case_document_columns
    @case_document_columns ||= jurisprudence_db.execute('PRAGMA table_info(case_documents)').map { |col| col[1] }
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] case_documents unavailable: #{e.message}")
    @case_document_columns = []
  end

  def case_documents_available?
    (CASE_DOCUMENT_REQUIRED - case_document_columns).empty?
  end

  # The published document of a case in one language, or nil. Keyed on
  # case_number, never cases.id: the table carries no id of the case, because
  # 69,295 of them had churned on production by 2026-09-17 under the INSERT OR
  # REPLACE the corpus writers used before they became UPSERTs.
  def find_case_document(case_number, language_id)
    return nil unless case_documents_available?

    optional = CASE_DOCUMENT_OPTIONAL.map { |col| case_document_columns.include?(col) ? col : 'NULL' }
    row = jurisprudence_db.execute(
      "SELECT language_id, full_text, #{optional.join(', ')} FROM case_documents " \
      "WHERE case_number = ? AND language_id = ? AND status = ? AND #{CASE_DOCUMENT_HAS_TEXT} LIMIT 1",
      [case_number, language_id, CASE_DOCUMENT_PUBLIC_STATUS]
    ).first
    return nil if row.nil?

    { language_id: row[0].to_i, full_text: row[1], summary: row[2], url: row[3], role: row[4] }
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] case_documents lookup failed: #{e.message}")
    nil
  end

  # [{ language_id:, href:, current:, role: }] - the stored text first, then
  # every other language the decision can be read in. For an opinion's sibling
  # language_id is its suffix, the language the Council filed it under, and
  # `current` is never set on it: a whole-stored pair can carry the same
  # language_id on both rows (3,857 :FR rows with a sibling carry 1), so
  # comparing languages would hide the link. role is the document's
  # where the table records one: the stored row has none of its own, so a
  # 'parallel' document beside it is the only way the view can tell that the
  # stored text is no translation either.
  #
  #   advisory opinion   the same key with the other suffix, a row in `cases`:
  #                      bilingual files were split into two rows, so 20,228
  #                      rows (10,114 pairs) have their counterpart there and
  #                      none in case_documents
  #   everything else    a published row in case_documents, shown on this page
  #
  # Both are searches of a unique index (sqlite_autoindex_cases_1, and the
  # UNIQUE (case_number, language_id) of case_documents).
  def language_versions_for(kase, shown_language_id)
    stored_language_id = page_language_id(kase)
    versions = [{ language_id: stored_language_id, href: jurisprudence_path(kase[:case_number]),
                  current: stored_language_id == shown_language_id }]

    advisory = ADVISORY_KEY.match(kase[:case_number].to_s)
    if advisory
      sibling = "#{advisory[1]}:#{advisory[2] == 'NL' ? 'FR' : 'NL'}"
      if jurisprudence_db.execute('SELECT 1 FROM cases WHERE case_number = ? LIMIT 1', [sibling]).first
        versions << { language_id: advisory[2] == 'NL' ? 2 : 1, href: jurisprudence_path(sibling), current: false }
      end
    elsif case_documents_available?
      # The same two conditions find_case_document serves under, status and
      # CASE_DOCUMENT_HAS_TEXT, so every pill leads to its document.
      role_col = case_document_columns.include?('role') ? 'role' : 'NULL'
      jurisprudence_db.execute(
        "SELECT language_id, #{role_col} FROM case_documents WHERE case_number = ? AND language_id != ? " \
        "AND status = ? AND #{CASE_DOCUMENT_HAS_TEXT} ORDER BY language_id LIMIT 3",
        [kase[:case_number], stored_language_id, CASE_DOCUMENT_PUBLIC_STATUS]
      ).each do |row|
        next unless CASE_LANGUAGE_IDS.include?(row[0].to_i)

        versions << { language_id: row[0].to_i, role: row[1], current: row[0].to_i == shown_language_id,
                      href: jurisprudence_path(kase[:case_number], language_id: row[0].to_i) }
      end
    end

    versions
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] language versions unavailable: #{e.message}")
    [{ language_id: shown_language_id, href: nil, current: true }]
  end

  # The listing language when the request names none: the site's own.
  def site_listing_language
    case I18n.locale
    when :nl then 'NL'
    when :de then 'DE'
    else 'FR'
    end
  end

  # [Integer] - the language_id values to list for a listing language.
  def listing_language_ids(lang)
    LISTING_LANGUAGE_IDS.fetch(lang.to_s.upcase, LISTING_LANGUAGE_IDS['FR'])
  end

  # Combined search + count using window function - eliminates separate COUNT query
  def search_cases_with_count(query, filters, limit, offset)
    fts_query = query.to_s.gsub(/[^\p{L}\p{N}\s]/, ' ').squish
    # A submitted query containing only punctuation has no searchable terms.
    # Do not turn it into an unrestricted counted listing, including past
    # the recent-listing limit.
    return [[], 0] if query.present? && fts_query.blank?

    conditions = []
    params = []

    # Exclude ADB (Arrestendatabank) legacy entries - they have no text and cause errors
    conditions << "case_number NOT LIKE 'ADB:%'"

    if fts_query.present?
      # Without the full-text index a query is unavailable. The LIKE fallback
      # that stood here scanned every case, and a transient error could make
      # fts_available? answer no (10:49 no-JS plan, C.2).
      raise SearchUnavailable, 'cases_fts is not available' unless fts_available?

      conditions << 'cases.id IN (SELECT rowid FROM cases_fts WHERE cases_fts MATCH ?)'
      params << fts_query
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
      court_filter = court_filter_for(filters[:court])
      conditions << "(#{Array(court_filter[:include]).map { 'court LIKE ?' }.join(' OR ')})"
      params.concat(Array(court_filter[:include]))
      Array(court_filter[:exclude]).each do |pattern|
        conditions << 'court NOT LIKE ?'
        params << pattern
      end
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
      language_ids = listing_language_ids(filters[:lang])
      conditions << "language_id IN (#{(['?'] * language_ids.size).join(', ')})"
      params.concat(language_ids)
    end

    return unless filters[:subject].present?

    conditions << 'subject_matter LIKE ?'
    params << "%#{filters[:subject]}%"
  end

  # The default listing: the decision-date index walked to one row past the
  # page. It replaced a COUNT(*) OVER() query that materialised every case of
  # the language to count it; on a 20,000-case fixture in production's column
  # order that took 449k VM steps and a full table scan for page 1, against
  # about 1,150 steps now, and its cost grew with the corpus. The unary +
  # keeps a language_id index out of the plan, which would otherwise read the
  # whole language to sort it. No total is counted: the pager links the next
  # page while there is one.
  def self.recent_listing_sql(language_count, order)
    placeholders = (['?'] * language_count).join(', ')
    ["SELECT #{LISTING_COLUMNS} FROM cases WHERE +language_id IN (#{placeholders})",
     "AND case_number NOT LIKE 'ADB:%' ORDER BY decision_date #{order}, id #{order} LIMIT ? OFFSET ?"].join(' ')
  end

  def recent_cases(limit, offset)
    language_ids = listing_language_ids(@lang)
    rows = jurisprudence_db.execute(self.class.recent_listing_sql(language_ids.size, @sort == 'date_asc' ? 'ASC' : 'DESC'),
                                    language_ids + [limit + 1, offset])
    [rows.first(limit).map { |row| listing_row(row) }, rows.size > limit]
  end

  def listing_row(row)
    { id: row[0], case_number: row[1], court: row[2], decision_date: row[3], summary: row[4], language_id: row[5],
      subject_matter: row[6], appellant: row[7] }
  end

  # One query path for the frame and the full page. A failed search is said
  # to have failed, never shown as "no cases found".
  def load_results(filters, offset)
    @cases = []
    @total_count = nil
    if @query.present? || filters.values.any?(&:present?)
      @cases, @total_count = search_cases_with_count(@query, filters.merge(lang: @lang), @per_page, offset)
      @total_pages = (@total_count.to_f / @per_page).ceil
    elsif offset >= MAX_RECENT_OFFSET
      @listing_limit_reached = true
      @total_pages = 0
    else
      @cases, more = recent_cases(@per_page, offset)
      @total_pages = @page + (more ? 1 : 0)
    end
  rescue StandardError => e
    # Name the database file: "no such table" here almost always means the
    # handle opened a stub or freshly created empty file, and the message
    # alone cannot show which.
    Rails.logger.error("Jurisprudence search error (db=#{@jurisprudence_db_path}): #{e.message}")
    @cases = []
    @total_count = nil
    @total_pages = 0
    @search_failed = true
  end

  # Only a yes is cached: a transient failure must not make the search
  # unavailable for ten minutes.
  def fts_available?
    return true if Rails.cache.read('jurisprudence_fts_available')

    jurisprudence_db.execute('SELECT 1 FROM cases_fts LIMIT 0')
    Rails.cache.write('jurisprudence_fts_available', true, expires_in: 10.minutes)
    true
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] FTS check failed: #{e.message}")
    false
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
      # The Council's Legislation section is not a court of its own: it sits
      # with the Council, named for what it does, so the two are next to each
      # other in the dropdown instead of one being filed under "Other".
      if court_name == 'Raad van State (wetgeving)'
        info = BelgianCourtService.court_info(:raad_van_state)
        label = locale == :nl ? 'Raad van State (afdeling Wetgeving)' : "Conseil d'État (section de législation)"
        grouped[info ? info[:level] : 1] << [label, court_name]
        next
      end

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

  # Every court writes its name in its own language, and the filter held only
  # the Dutch one. Measured on production 2026-09-16: "Raad van State" plus the
  # French language filter returned 2 rows of 57,983, and "Hof van Cassatie"
  # returned none of 9,336 - so in French, picking a court emptied the list.
  #
  # `exclude` is what keeps the Council's two sections apart: its Legislation
  # section advises on draft law and files under the same name, so without it
  # 80,000 advisory opinions would answer a search for its rulings.
  COURT_FILTERS = {
    'Grondwettelijk Hof' => {
      include: ['%Grondwettelijk Hof%', '%Arbitragehof%', '%Cour constitutionnelle%', "%Cour d'arbitrage%"]
    },
    'Hof van Cassatie' => { include: ['%Hof van Cassatie%', '%Cour de cassation%'] },
    'Raad van State' => {
      include: ['%Raad van State%', "%Conseil d'État%", '%Conseil d’État%', "%Conseil d'Etat%"],
      exclude: ['%afdeling Wetgeving%', '%section de législation%']
    },
    'Raad van State (wetgeving)' => {
      include: ['%afdeling Wetgeving%', '%section de législation%']
    },
    'Hof van Beroep' => { include: ['%Hof van beroep%', "%Cour d'appel%"] },
    'Arbeidshof' => { include: ['%Arbeidshof%', '%Cour du travail%'] },
    'Arbeidsrechtbank' => { include: ['%Arbeidsrechtbank%', '%Tribunal du travail%'] },
    'Ondernemingsrechtbank' => { include: ['%Ondernemingsrechtbank%', "%Tribunal de l'entreprise%"] },
    'Rechtbank eerste aanleg' => {
      include: ['%Rechtbank eerste aanleg%', '%Rechtbank van eerste aanleg%', '%Tribunal de première instance%']
    },
    'Beslagrechter' => { include: ['%Beslagrechter%', '%Juge des saisies%'] },
    'Handhavingscollege' => { include: ['%Handhavingscollege%'] }
  }.freeze

  def court_filter_for(category)
    COURT_FILTERS.fetch(category) { { include: ["%#{category}%"] } }
  end

  def normalize_court(court)
    return nil if court.blank? || court == 'Unknown'

    case court
    when /Grondwettelijk Hof|Cour Constitutionnelle/i
      'Grondwettelijk Hof'
    when /Hof van Cassatie|Cour de Cassation/i
      'Hof van Cassatie'
    when /afdeling Wetgeving|section de législation/i
      'Raad van State (wetgeving)'
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
