# frozen_string_literal: true

# Helpers for jurisprudence (court cases) views
module JurisprudenceHelper
  # JuPortal publishes each decision under a LANGUAGE-suffixed name, and the
  # two language fields we hold do NOT mean the same thing:
  #
  #   cases.url          the JuPortal path that DELIVERED the document,
  #                      `https://juportal.be/content/<ECLI>/<LANG>`
  #   cases.language_id  the language of the TEXT, corrected by the scraper's
  #                      detect_language_id - because JuPortal serves the Dutch
  #                      original on /FR URLs when no translation exists
  #
  # They disagree on 1,410 of 175,484 rows, and that disagreement is the
  # scraper working as designed, not a defect.
  #
  # The URL segment is the right key here, because it is the one JuPortal
  # files the document under. Measured on mismatched rows (2026-09-01): most
  # often both suffixes return the same bytes or both 404, but where the two
  # differ the suffix selects a genuine translation - ECLI:BE:RVSCE:2011:
  # ORD.6.839 serves 90,971 bytes as _NL and 91,358 as _FR. Pairing the PDF
  # with the page's own language is what makes the button match the page it
  # sits on. language_id is the fallback only when the url cannot say.
  JUPORTAL_LANGUAGES = %w[NL FR DE].freeze
  JUPORTAL_CONTENT_PREFIX = 'https://juportal.be/content/'
  JUPORTAL_PDF_PREFIX = 'https://juportal.be/JUPORTAwork/'

  # Rows fetched from the Raad van State's own site because JuPortal does not
  # carry them (lib/tasks/scrape_raadvst.py, 2026-09-14). The stored url is
  # the judgment's PDF there. Matched as a WHOLE and rebuilt from its parts,
  # never echoed: a corpus value is data, not a destination, exactly as the
  # JuPortal PDF rule below insists. `&type=1` is how the site is asked for an
  # order (see RAADVST_KEY), so a stored url may carry it.
  RAADVST_URL = %r{\Ahttps://www\.raadvst-consetat\.be/arr\.php\?nr=(\d{1,6})&l=(nl|fr)(&type=1)?\z}
  # A Council of State judgment (ARR) or admissibility order (ORD) by its key,
  # the number written with a dot per thousand: ARR.258.811, ORD.16.307,
  # ORD.100. Read on production 2026-09-26 from the key index alone: all
  # 109,631 RVSCE keys have one of these shapes.
  #
  # The site serves both from arr.php?nr=<number>&l=<nl|fr>, and an order only
  # with &type=1: without it order 16.805 answered the "not accessible" page,
  # with it its PDF (docs/ops/council-weekly-delta.md, section 4.2).
  RAADVST_KEY = /\AECLI:BE:RVSCE:\d{4}:(ARR|ORD)\.(\d{1,3}(?:\.\d{3})?)\z/
  # The site's two languages, by language_id. A German text (3) gets no link:
  # arr.php takes l=nl or l=fr, and a guess would be a dead link.
  RAADVST_KEY_LANGUAGES = { 1 => 'nl', 2 => 'fr' }.freeze
  # The Legislation section publishes each advisory opinion as a PDF of its own,
  # and that address IS the document - there is no page around it, and JuPortal
  # holds none of them.
  RAADVST_PDF_URL = %r{\Ahttps://www\.raadvst-consetat\.be/dbx/(adviezen|gutachten)/(\d{1,6})\.pdf\z}

  # Whether the row is an advisory opinion of the Council's Legislation
  # section (RVSADV keys): an advice, not a judgment and not a rule in force,
  # which the page must not call an "arrest" (WW-RVSADV-01).
  def advisory_opinion?(kase)
    kase[:case_number].to_s.start_with?('RVSADV:')
  end

  # @param kase [Hash] the case hash from the controller (:url, :language_id)
  # @return [String] 'NL', 'FR' or 'DE'
  def juportal_language(kase)
    suffix = kase[:url].to_s.rstrip.split('/').last.to_s.upcase
    return suffix if JUPORTAL_LANGUAGES.include?(suffix)

    kase[:language_id].to_s == '2' ? 'FR' : 'NL'
  end

  # The judgment on the Raad van State's own site, for rows sourced there, or
  # nil. Rebuilt from the validated number and language. An order is asked
  # with &type=1 whether or not the stored url says so: the order rows were
  # stored without it, and that form answers "not accessible".
  def raadvst_source_url(kase)
    stored = kase[:url].to_s.strip
    match = RAADVST_URL.match(stored)
    return raadvst_judgment_url(match[1], match[2], order: match[3].present? || raadvst_order?(kase)) if match

    pdf = RAADVST_PDF_URL.match(stored)
    return nil unless pdf

    "https://www.raadvst-consetat.be/dbx/#{pdf[1]}/#{pdf[2]}.pdf"
  end

  # The Council's own copy of a Council judgment or order whose row keeps
  # JuPortal's url and text (the B rows of the 2026-09-26 JuPortal merge, about
  # 6,500), or nil. Derived from the KEY and the row's language_id only, never
  # from the stored url or text: the key is validated whole by RAADVST_KEY, so
  # nothing a corpus value says can aim this link anywhere else. Any other key
  # (another court, an advisory opinion) gets nothing.
  def raadvst_key_url(kase)
    key = RAADVST_KEY.match(kase[:case_number].to_s)
    language = RAADVST_KEY_LANGUAGES[kase[:language_id].to_i]
    return nil unless key && language

    raadvst_judgment_url(key[2].delete('.'), language, order: key[1] == 'ORD')
  end

  def raadvst_judgment_url(number, language, order:)
    "https://www.raadvst-consetat.be/arr.php?nr=#{number}&l=#{language}#{'&type=1' if order}"
  end

  # Whether the key names a Council order (ORD), which the site serves only
  # with &type=1.
  def raadvst_order?(kase)
    RAADVST_KEY.match(kase[:case_number].to_s)&.captures&.first == 'ORD'
  end

  # The case's page on JuPortal. Prefers the stored URL, which carries the
  # language segment the constructed form was dropping.
  def juportal_content_url(kase)
    # A Raad van State row is exactly one JuPortal does not have. Building the
    # JuPortal address from its ECLI would link to the page that 404s.
    return nil if raadvst_source_url(kase)

    stored = kase[:url].to_s.strip
    return stored if stored.start_with?(JUPORTAL_CONTENT_PREFIX)

    ecli = kase[:case_number].to_s
    return nil unless ecli.start_with?('ECLI:')

    "#{JUPORTAL_CONTENT_PREFIX}#{ecli}/#{juportal_language(kase)}"
  end

  # The scanned original, when JuPortal holds one.
  #
  # Deliberately WITHOUT the `?Version=` parameter that JuPortal's own markup
  # carries: with it the request 302s away, without it the file is served
  # directly (200 application/pdf).
  def juportal_pdf_url(kase)
    ecli = kase[:case_number].to_s
    return nil unless ecli.start_with?('ECLI:')

    "#{JUPORTAL_PDF_PREFIX}#{ecli}_#{juportal_language(kase)}.pdf"
  end

  # The link to offer, or nil for none. Three states, and the difference
  # between the last two is the whole point of storing the column:
  #
  #   a URL   the scraper saw the link on the case page   -> offer it
  #   ''      the scraper looked and there is no scan     -> offer nothing,
  #                                                          ask no one
  #   nil     nobody has looked (row predates the column) -> ask JuPortal
  #                                                          once, then cache
  #
  # The stored answer is free and exact: the scraper reads it out of the page
  # it already fetches. The live check exists only to carry the 175k rows
  # scraped before the column did, and each answer it gets is cached for a
  # month. As rescrapes backfill the column, this path goes quiet on its own.
  def juportal_pdf_link(kase)
    # Its PDF is the Raad van State source link itself; asking JuPortal about a
    # document it does not hold would cost a request per render and say no.
    return nil if raadvst_source_url(kase)

    url = juportal_pdf_url(kase)
    return nil if url.blank?

    stored = kase[:pdf_url]
    # Recorded absence. Believe it.
    return nil if stored && stored.to_s.strip.empty?
    # Recorded presence, but only from JuPortal - a corpus value must never be
    # able to aim this button at another host.
    return stored if stored.to_s.start_with?(JUPORTAL_PDF_PREFIX)

    JuportalPdf.available?(url) ? url : nil
  end

  # Every language label on the case page was a binary `== '1' ? 'NL' : 'FR'`,
  # so a German value could only ever render as French. case_documents admits
  # language_id 3 and original_language_id takes it for the 228 numbers the
  # loader stamps 'de-masthead', so the three are named here once. The BADGE of
  # those rows still says FR or NL: it follows cases.language_id, which holds no
  # 3 on production (see jurisprudence_translation?). nil for anything else: a
  # caller shows nothing rather than guessing.
  CASE_LANGUAGE_LABELS = { 1 => 'NL', 2 => 'FR', 3 => 'DE' }.freeze

  # @param language_id [Integer, String, nil] 1, 2 or 3
  # @return [String, nil] 'NL', 'FR', 'DE' or nil
  def jurisprudence_language_label(language_id)
    CASE_LANGUAGE_LABELS[language_id.to_i]
  end

  # The same, as the BCP 47 tag schema.org's inLanguage expects.
  def jurisprudence_language_code(language_id)
    jurisprudence_language_label(language_id)&.downcase
  end

  # How a parliamentary document that cites an opinion is named on the
  # opinion page: the assembly in the page's language, then legislature,
  # dossier and document number as the Chamber prints them ("Kamer 54-1234/001").
  # The parts a row lacks are left out rather than shown as blanks.
  PARLIAMENT_LABELS = {
    'chamber' => { nl: 'Kamer', fr: 'Chambre', de: 'Kammer', en: 'Chamber' },
    'senate' => { nl: 'Senaat', fr: 'Sénat', de: 'Senat', en: 'Senate' }
  }.freeze

  # @param doc [Hash] :parliament, :legislature, :dossier_number, :document_number
  # @return [String]
  def parliamentary_document_label(doc)
    locale = PARLIAMENT_LABELS.dig('chamber', I18n.locale) ? I18n.locale : :nl
    assembly = PARLIAMENT_LABELS.dig(doc[:parliament].to_s, locale) || doc[:parliament].to_s.capitalize
    reference = [doc[:legislature], doc[:dossier_number]].map(&:presence).compact.join('-')
    reference = [reference.presence, doc[:document_number].presence].compact.join('/')
    [assembly, reference.presence].compact.join(' ')
  end

  # Whether the text on screen gets the 'translation' pill. role is the shown
  # document's as the loader recorded it, nil for the stored row, which has none.
  #
  #   official language unknown   only a document recorded as 'translation'
  #   official language known     never a text in that language, never a
  #                               'parallel' or an 'original'; a role-less
  #                               stored row is INFERRED to be one, from its
  #                               language_id not being the official language
  #
  # The inference takes cases.language_id for the language of the stored text,
  # and beside a German original it cannot. The column has only ever held 1 and
  # 2, so a German text sits under one of them: measured on production
  # 2026-09-20, 31 Council judgments open with the masthead STAATSRAT, 30 under
  # language_id 2 (29 with a JuPortal /FR url) and 1 under 1, and the sweep,
  # reading the Council's own files, counted 121 German mastheads stored under
  # language_id 2 in its first 69,037 numbers. The loader stamps
  # 'de-masthead' on 228 numbers, writes no German document and leaves
  # language_id alone, so inferring put 'translation' above the German original
  # itself. Those rows cannot be told here from a true French translation of a
  # German judgment, so the page says nothing rather than guess: the price is
  # that translation's pill and nothing else. Rows corrected to language_id 3
  # need no exception, the language comparison already answers no for them.
  #
  # @param original_language_id [Integer, nil] cases.original_language_id
  # @param page_language_id [Integer] the language of the text on screen
  # @param role [String, nil] 'original', 'translation', 'parallel' or nil
  def jurisprudence_translation?(original_language_id, page_language_id, role)
    return role == 'translation' unless jurisprudence_language_label(original_language_id)
    return false if original_language_id.to_i == page_language_id.to_i
    return true if role == 'translation'

    role.nil? && original_language_id.to_i != 3
  end

  # Court name to service key mapping
  COURT_KEY_MAP = {
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
    'Handhavingscollege' => :handhavingscollege,
    'Vredegerecht' => :vredegerecht,
    'Politierechtbank' => :politierechtbank
  }.freeze

  # Get appeal info for a court (for linking to deadline calculator)
  # @param court_name [String] The court name
  # @return [Hash, nil] Hash with :deadline_days and :appeal_to, or nil
  def court_appeal_info(court_name)
    return nil if court_name.blank?

    normalized = normalize_court_for_lookup(court_name)
    court_key = COURT_KEY_MAP[normalized]
    return nil unless court_key

    info = BelgianCourtService.court_info(court_key)
    return nil unless info && info[:appeal_deadline_days]

    {
      deadline_days: info[:appeal_deadline_days],
      appeal_to: info[:appeal_to]
    }
  end

  # Renders court level indicator (hierarchy badge)
  # @param court_name [String] The court name
  # @return [ActiveSupport::SafeBuffer, nil] HTML for level indicator
  def court_level_indicator(court_name)
    return nil if court_name.blank?

    normalized = normalize_court_for_lookup(court_name)
    court_key = COURT_KEY_MAP[normalized]
    info = court_key ? BelgianCourtService.court_info(court_key) : nil
    return nil unless info

    level = info[:level]
    colors = {
      1 => 'bg-purple-100 dark:bg-purple-900 text-purple-800 dark:text-purple-200',
      2 => 'bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200',
      3 => 'bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-200',
      4 => 'bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300'
    }

    content_tag(:span, "L#{level}",
                class: "inline-flex items-center justify-center w-5 h-5 rounded-full text-xs font-medium #{colors[level] || colors[4]}",
                title: BelgianCourtService.level_label(level, I18n.locale))
  end

  # Extract a human-readable court title from an ECLI code
  # ECLI:BE:GHCC:2024:123 → "Grondwettelijk Hof"
  # ECLI:BE:CASS:2024:456 → "Hof van Cassatie"
  # @param ecli [String] The ECLI case number
  # @param locale [Symbol] :nl or :fr
  # @return [String] Human-readable court name or the raw ECLI
  def ecli_court_title(ecli, locale = I18n.locale)
    return ecli if ecli.blank?

    # Extract court code from ECLI (format: ECLI:BE:COURTCODE:YEAR:NUMBER)
    parts = ecli.to_s.split(':')
    return ecli unless parts.length >= 4

    court_code = parts[2].to_s.upcase
    court_names = {
      'GHCC' => { nl: 'Grondwettelijk Hof', fr: 'Cour constitutionnelle' },
      'CASS' => { nl: 'Hof van Cassatie', fr: 'Cour de cassation' },
      'RVS' => { nl: 'Raad van State', fr: "Conseil d'État" },
      'RVST' => { nl: 'Raad van State', fr: "Conseil d'État" },
      'RSCE' => { nl: 'Raad van State', fr: "Conseil d'État" },
      'APP' => { nl: 'Hof van Beroep', fr: "Cour d'appel" },
      'ARBH' => { nl: 'Arbeidshof', fr: 'Cour du travail' },
      'EAAB' => { nl: 'Rechtbank eerste aanleg', fr: 'Tribunal de première instance' },
      'EARB' => { nl: 'Arbeidsrechtbank', fr: 'Tribunal du travail' },
      'EAON' => { nl: 'Ondernemingsrechtbank', fr: "Tribunal de l'entreprise" },
      'BESL' => { nl: 'Beslagrechter', fr: 'Juge des saisies' },
      'VRED' => { nl: 'Vredegerecht', fr: 'Justice de paix' },
      'POL' => { nl: 'Politierechtbank', fr: 'Tribunal de police' }
    }

    name = court_names[court_code]&.dig(locale == :nl ? :nl : :fr)
    name || ecli
  end

  private

  def badge_classes
    'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-(--accent-100) dark:bg-(--accent-900) text-(--accent-700) dark:text-(--accent-400)'
  end

  def tooltip_content(level_label, description, info, locale)
    content_tag(:span,
                class: 'invisible group-hover:visible absolute z-50 bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-2 text-xs text-white bg-gray-900 dark:bg-gray-700 rounded-lg shadow-lg whitespace-nowrap max-w-xs') do
      lines = [
        # This tooltip sits on bg-gray-900 / dark:bg-gray-700, a dark ground in
        # BOTH modes, so it needs the light end of each ramp: --accent-400 is
        # 6.98:1 on gray-900 and --accent-600 is 6.18:1 on gray-700. Taking the
        # ramp's usual light-mode step here would put a deep blue on near-black.
        content_tag(:span, level_label, class: 'font-semibold text-(--accent-400) dark:text-(--accent-600)'),
        content_tag(:br),
        content_tag(:span, description, class: 'text-gray-200')
      ]

      # Add appeal info if available
      if info[:appeal_to]
        appeal_name = locale == :nl ? BelgianCourtService.court_info(info[:appeal_to])[:name_nl] : BelgianCourtService.court_info(info[:appeal_to])[:name_fr]
        appeal_text = locale == :nl ? "Beroep → #{appeal_name} (#{info[:appeal_deadline_days]}d)" : "Appel → #{appeal_name} (#{info[:appeal_deadline_days]}j)"
        lines << content_tag(:br)
        lines << content_tag(:span, appeal_text, class: 'text-green-300 text-xs')
      end

      safe_join(lines)
    end
  end

  def normalize_court_for_lookup(court_name)
    return nil if court_name.blank?

    name = court_name.to_s

    # Try exact match first
    return name if COURT_KEY_MAP.key?(name)

    # Try pattern matching
    COURT_KEY_MAP.keys.find do |key|
      name.downcase.include?(key.downcase) ||
        BelgianCourtService.court_info(COURT_KEY_MAP[key])[:name_fr]&.downcase&.then { |fr| name.downcase.include?(fr) }
    end
  end

  # The years the corpus actually holds decisions in, newest first.
  #
  # Both year dropdowns counted down from a hardcoded 1985, which hid every
  # older ruling in them: the corpus reaches back to 1921, with a continuous
  # series from 1937 (the 22,289 Arr.Cass. rulings ingested from KU Leuven) and
  # the Council of State's advisory opinions from 1947. Listing only the years
  # that exist also keeps the gap between the old series and the modern corpus
  # out of the dropdown.
  def jurisprudence_years
    Rails.cache.fetch('jurisprudence_available_years', expires_in: 24.hours) do
      path = ENV.fetch('JURISPRUDENCE_SOURCE_DB') { Rails.root.join('storage', 'jurisprudence.db').to_s }
      db = SQLite3::Database.new(path, readonly: true)
      begin
        db.execute("SELECT DISTINCT substr(decision_date, 1, 4) FROM cases WHERE decision_date >= '1800'")
          .map { |row| row.first.to_i }
          .grep(1800..(Date.current.year + 1))
          .sort
          .reverse
      ensure
        db.close
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[Jurisprudence] year list unavailable: #{e.message}")
    Date.current.year.downto(1985).to_a
  end
end
