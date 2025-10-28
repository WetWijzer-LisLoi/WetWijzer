# frozen_string_literal: true

# Helpers for law views
module LawsHelper
  # Renders jurisdiction info for a law based on its title
  # @param title [String] The law title
  # @param locale [Symbol] The locale (:nl or :fr)
  # @return [ActiveSupport::SafeBuffer, nil] HTML for jurisdiction info or nil
  def jurisdiction_info(title, locale = I18n.locale)
    courts = BelgianCourtService.detect_relevant_courts(title, nil, locale)
    return nil if courts.empty?

    content_tag(:div, class: 'mt-3 p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg') do
      safe_join([
        content_tag(:h4, class: 'text-sm font-medium text-gray-700 dark:text-gray-300 mb-2') do
          locale == :fr ? '⚖️ Juridictions compétentes' : '⚖️ Bevoegde rechtbanken'
        end,
        content_tag(:div, class: 'flex flex-wrap gap-2') do
          safe_join(courts.first(4).map { |court| jurisdiction_badge(court, locale) })
        end
      ])
    end
  end

  # Renders a single jurisdiction badge with tooltip
  # @param court [Hash] Court info from BelgianCourtService
  # @param locale [Symbol] The locale
  # @return [ActiveSupport::SafeBuffer] HTML for the badge
  def jurisdiction_badge(court, locale = I18n.locale)
    level_colors = {
      1 => 'bg-purple-100 dark:bg-purple-900/50 text-purple-800 dark:text-purple-200 border-purple-200 dark:border-purple-700',
      2 => 'bg-blue-100 dark:bg-blue-900/50 text-blue-800 dark:text-blue-200 border-blue-200 dark:border-blue-700',
      3 => 'bg-green-100 dark:bg-green-900/50 text-green-800 dark:text-green-200 border-green-200 dark:border-green-700',
      4 => 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 border-gray-200 dark:border-gray-600'
    }

    color = level_colors[court[:level]] || level_colors[3]

    content_tag(:span, class: "inline-flex items-center gap-1 px-2 py-1 text-xs font-medium rounded border #{color}",
                       title: court[:description]) do
      safe_join([
        content_tag(:span, "L#{court[:level]}", class: 'font-bold'),
        content_tag(:span, court[:name])
      ])
    end
  end

  # Quick link to deadline calculator with pre-filled court
  # @param court_key [Symbol] The court key
  # @return [String] URL to deadline calculator
  def deadline_calculator_link(court_key)
    info = BelgianCourtService.court_info(court_key)
    return tools_deadline_calculator_path unless info&.dig(:appeal_deadline_days)

    tools_deadline_calculator_path(deadline_days: info[:appeal_deadline_days])
  end
end
