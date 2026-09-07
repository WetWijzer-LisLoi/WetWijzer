# frozen_string_literal: true

# Helpers for law views
module LawsHelper
  FISCONET_STYLE_ATTR = /\sstyle="([^"]*)"/i
  # The stored HTML entity-encodes the colon (font-style&#58;italic).
  FISCONET_ITALIC = /font-style\s*(?::|&#58;)\s*italic/i

  # Reduce Fisconet's inline styles to the one that carries meaning.
  #
  # Fisconet HTML puts a style attribute on nearly every span: font-family
  # 'titillium web', 10pt, text-align justify, margins - its own typography,
  # which this site overrides anyway. Only font-style:italic is content: it
  # marks the amendment annotations ("van toepassing vanaf ..., gewijzigd
  # door ..."). Keep that as a class and drop the rest BEFORE sanitizing.
  #
  # This is not cosmetic. With `style` in the sanitizer's allowlist every one
  # of those attributes went through Loofah's CSS scrubber: 91,077 of them on
  # the registration-duties code, 25 of its 29 seconds of cold render. Without
  # `style` the same page sanitizes in under four. One regex pass here costs
  # milliseconds. (No source tag carries both class and style, so the class
  # is never clobbered; measured on the live corpus.)
  def fisconet_reduce_inline_styles(html)
    return html if html.blank?

    html.gsub(FISCONET_STYLE_ATTR) { Regexp.last_match(1).match?(FISCONET_ITALIC) ? ' class="italic"' : '' }
  end

  # Renders a single jurisdiction badge with tooltip
  # @param court [Hash] Court info from BelgianCourtService
  # @param locale [Symbol] The locale
  # @return [ActiveSupport::SafeBuffer] HTML for the badge
  def jurisdiction_badge(court, _locale = I18n.locale)
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
end
