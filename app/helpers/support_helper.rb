# frozen_string_literal: true

module SupportHelper
  SUPPORT_DECORATIONS = {
    star: ['⭐', 'M12 3l2.8 5.7 6.2.9-4.5 4.4 1.1 6.2L12 17.3l-5.6 2.9 1.1-6.2L3 9.6l6.2-.9z'],
    chat: ['💬', 'M5 4h14a2 2 0 012 2v10a2 2 0 01-2 2h-7l-5 4v-4H5a2 2 0 01-2-2V6a2 2 0 012-2zM7 9h10M7 13h7'],
    document: ['📜', 'M14 3H5v18h14V8zM14 3v5h5M8 12h8m-8 4h8'],
    robot: ['🤖', 'M12 3v3M9 3h6M5 7h14v13H5zM2 11v5m20-5v5M8 11h1m6 0h1M8 16h8'],
    coffee: ['☕', 'M4 9h13v8a4 4 0 01-4 4H8a4 4 0 01-4-4zM17 10h2a3 3 0 010 6h-2M7 3v3m4-3v3m4-3v3'],
    megaphone: ['📢', 'M3 9h5l12-5v16L8 15H3zM8 15l2 6H6l-2-6M23 9v6'],
    link: ['🔗', 'M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-2 2M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l2-2'],
    note: ['📝', 'M11 4H4v17h17v-7M14 13l-5 2 2-5 8-8 3 3zM17 4l3 3'],
    heart: ['❤️', 'M20.8 4.6a5.5 5.5 0 00-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 00-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 000-7.8z']
  }.freeze

  # CSS selects the theme presentation. Classic/no-JS retains the original
  # decoration; neither variant repeats the adjacent text to assistive tech.
  def support_decoration(name)
    emoji, path = SUPPORT_DECORATIONS.fetch(name)
    tag.span(class: 'ww-support-decoration', 'aria-hidden': true) do
      safe_join([
                  tag.span(emoji, class: 'ww-support-emoji'),
                  tag.svg(class: 'ww-support-icon', fill: 'none', stroke: 'currentColor', viewBox: '0 0 24 24',
                          'aria-hidden': true, focusable: false) do
                    tag.path(d: path, 'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round')
                  end
                ])
    end
  end
end
