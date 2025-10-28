# frozen_string_literal: true

# Helpers for jurisprudence (court cases) views
module JurisprudenceHelper
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

  # Renders a court badge with tooltip showing jurisdiction description
  # @param court_name [String] The court name from the database
  # @param locale [Symbol] The locale for translations (:nl or :fr)
  # @return [ActiveSupport::SafeBuffer] HTML for the court badge with tooltip
  def court_badge_with_tooltip(court_name, locale = I18n.locale)
    return content_tag(:span, court_name&.truncate(30), class: badge_classes) if court_name.blank?

    # Normalize court name to find the key
    normalized = normalize_court_for_lookup(court_name)
    court_key = COURT_KEY_MAP[normalized]
    info = court_key ? BelgianCourtService.court_info(court_key) : nil

    if info
      display_name = locale == :fr ? info[:name_fr] : info[:name_nl]
      description = locale == :fr ? info[:description_fr] : info[:description_nl]
      level_label = BelgianCourtService.level_label(info[:level], locale)

      content_tag(:span, class: "#{badge_classes} cursor-help group relative") do
        safe_join([
          content_tag(:span, display_name.truncate(25)),
          tooltip_content(level_label, description, info, locale)
        ])
      end
    else
      content_tag(:span, court_name&.truncate(30), class: badge_classes)
    end
  end

  # Renders appeal route info badge
  # @param court_name [String] The court name
  # @param locale [Symbol] The locale
  # @return [ActiveSupport::SafeBuffer, nil] HTML for appeal route badge or nil
  def appeal_route_badge(court_name, locale = I18n.locale)
    return nil if court_name.blank?

    normalized = normalize_court_for_lookup(court_name)
    court_key = COURT_KEY_MAP[normalized]
    return nil unless court_key

    route = BelgianCourtService.appeal_route(court_key)
    return nil unless route && route[:to]

    to_name = locale == :fr ? route[:to_info][:name_fr] : route[:to_info][:name_nl]
    days = route[:deadline_days]

    label = locale == :fr ? "→ #{to_name} (#{days}j)" : "→ #{to_name} (#{days}d)"

    content_tag(:span, label, 
                class: 'inline-flex items-center px-1.5 py-0.5 rounded text-xs bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 ml-1',
                title: locale == :fr ? "Délai d'appel: #{days} jours" : "Beroepstermijn: #{days} dagen")
  end

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

  private

  def badge_classes
    'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200'
  end

  def tooltip_content(level_label, description, info, locale)
    content_tag(:span, class: 'invisible group-hover:visible absolute z-50 bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-2 text-xs text-white bg-gray-900 dark:bg-gray-700 rounded-lg shadow-lg whitespace-nowrap max-w-xs') do
      lines = [
        content_tag(:span, level_label, class: 'font-semibold text-blue-300'),
        content_tag(:br),
        content_tag(:span, description, class: 'text-gray-200')
      ]

      # Add appeal info if available
      if info[:appeal_to]
        appeal_name = locale == :fr ? BelgianCourtService.court_info(info[:appeal_to])[:name_fr] : BelgianCourtService.court_info(info[:appeal_to])[:name_nl]
        appeal_text = locale == :fr ? "Appel → #{appeal_name} (#{info[:appeal_deadline_days]}j)" : "Beroep → #{appeal_name} (#{info[:appeal_deadline_days]}d)"
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
        (BelgianCourtService.court_info(COURT_KEY_MAP[key])[:name_fr]&.downcase&.then { |fr| name.downcase.include?(fr) })
    end
  end
end
