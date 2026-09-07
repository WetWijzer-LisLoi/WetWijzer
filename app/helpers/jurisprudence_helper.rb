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

  # @param kase [Hash] the case hash from the controller (:url, :language_id)
  # @return [String] 'NL', 'FR' or 'DE'
  def juportal_language(kase)
    suffix = kase[:url].to_s.rstrip.split('/').last.to_s.upcase
    return suffix if JUPORTAL_LANGUAGES.include?(suffix)

    kase[:language_id].to_s == '2' ? 'FR' : 'NL'
  end

  # The case's page on JuPortal. Prefers the stored URL, which carries the
  # language segment the constructed form was dropping.
  def juportal_content_url(kase)
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
end
