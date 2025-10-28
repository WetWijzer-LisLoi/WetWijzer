# frozen_string_literal: true

module ThemeHelper
  # Theme configuration - single source of truth for all theme colors
  # Used by: header theme selector, CSS generation, and any other theme-related components
  #
  # To add a new theme:
  # 1. Add it here with swatch, accent_500, accent_700 colors
  # 2. Add CSS definition in app/javascript/stylesheets/themes/_accent.scss
  # 3. Add translation in config/locales/*.yml (theme.your_theme_name)
  # 4. Refresh page - button appears automatically!
  #
  THEMES = {
    # Professional themes (first row) - use accent-700
    slate: { name: 'slate', swatch: '#6b7280', accent_500: '#6b7280', accent_700: '#374151', row: 1 },
    indigo: { name: 'indigo', swatch: '#4f46e5', accent_500: '#818cf8', accent_700: '#4f46e5', row: 1 },
    sky: { name: 'sky', swatch: '#0284c7', accent_500: '#38bdf8', accent_700: '#0284c7', row: 1 },
    teal: { name: 'teal', swatch: '#0d9488', accent_500: '#2dd4bf', accent_700: '#0d9488', row: 1 },
    cyan: { name: 'cyan', swatch: '#0891b2', accent_500: '#22d3ee', accent_700: '#0891b2', row: 1 },
    green: { name: 'green', swatch: '#16a34a', accent_500: '#4ade80', accent_700: '#16a34a', row: 1 },
    purple: { name: 'purple', swatch: '#9333ea', accent_500: '#c084fc', accent_700: '#9333ea', row: 1 },
    red: { name: 'red', swatch: '#dc2626', accent_500: '#f87171', accent_700: '#dc2626', row: 1 },

    # Vibrant/Fun themes (second row) - use accent-500
    original: { name: 'original', swatch: '#ffffff', accent_500: '#3b82f6', accent_700: '#1d4ed8', row: 2 },
    blue: { name: 'blue', swatch: '#3b82f6', accent_500: '#3b82f6', accent_700: '#1d4ed8', row: 2 },
    rose: { name: 'rose', swatch: '#f43f5e', accent_500: '#f43f5e', accent_700: '#be123c', row: 2 },
    amber: { name: 'amber', swatch: '#d97706', accent_500: '#d97706', accent_700: '#92400e', row: 2 },
    emerald: { name: 'emerald', swatch: '#10b981', accent_500: '#10b981', accent_700: '#047857', row: 2 },
    violet: { name: 'violet', swatch: '#8b5cf6', accent_500: '#8b5cf6', accent_700: '#6d28d9', row: 2 },
    fuchsia: { name: 'fuchsia', swatch: '#d946ef', accent_500: '#d946ef', accent_700: '#a21caf', row: 2 },
    pink: { name: 'pink', swatch: '#ec4899', accent_500: '#ec4899', accent_700: '#be185d', row: 2 }
  }.freeze

  # Get themes for a specific row (1 or 2)
  def themes_for_row(row_number)
    THEMES.select { |_key, theme| theme[:row] == row_number }
  end

  # Get swatch color for a theme
  def theme_swatch_color(theme_name)
    THEMES.dig(theme_name.to_sym, :swatch) || '#3b82f6' # default to blue
  end

  # Generate button classes for a theme swatch
  # Special handling for white swatches (original only)
  def theme_button_classes(theme_name)
    theme = THEMES[theme_name.to_sym]
    return '' unless theme

    base = 'w-6 h-6 rounded-full border border-gray-300 dark:border-gray-600 hover:ring-2'
    ring_color = "ring-#{theme_name}-300"
    focus = 'focus-visible:ring-2 focus-visible:ring-[var(--accent-500)] focus:outline-none'
    transitions = 'transition-all duration-150 ease-out motion-reduce:transition-none active:scale-95'

    # Only "original" uses bg classes (white in light, midnight in dark)
    if theme_name.to_s == 'original'
      "#{base} bg-white dark:bg-[#0f172a] #{ring_color} #{focus} #{transitions}"
    else
      "#{base} #{ring_color} #{focus} #{transitions}"
    end
  end

  # Get inline style for swatch color (nil if using bg class)
  def theme_button_style(theme_name)
    return nil if theme_name.to_s == 'original'

    swatch = theme_swatch_color(theme_name)
    "background-color: #{swatch};"
  end
end
