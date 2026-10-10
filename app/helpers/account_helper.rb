# frozen_string_literal: true

module AccountHelper
  ACCOUNT_ICON_PATHS = {
    user: 'M16 7a4 4 0 11-8 0 4 4 0 018 0zM5 21a7 7 0 0114 0',
    chart: 'M4 20h16M7 16v-4m5 4V8m5 8V4',
    lock: 'M8 11V7a4 4 0 018 0v4M6 11h12v10H6zM12 15v2',
    globe: 'M21 12a9 9 0 11-18 0 9 9 0 0118 0zM3 12h18M12 3c-4 4-4 14 0 18M12 3c4 4 4 14 0 18',
    clipboard: 'M9 4H5v17h14V4h-4M9 3h6v4H9zM8 12h8m-8 4h8',
    key: 'M14 10a5 5 0 11-10 0 5 5 0 0110 0zM13 13l8 8m-4-4l2-2',
    shield: 'M12 3l8 3v6c0 5-4 8-8 10-4-2-8-5-8-10V6zM8 12l3 3 5-6',
    document: 'M14 3H5v18h14V8zM14 3v5h5M8 12h8m-8 4h8',
    credit: 'M21 12a9 9 0 11-18 0 9 9 0 0118 0zM15 8h-4a2 2 0 000 4h2a2 2 0 010 4H9m3-10v12',
    undo: 'M9 5L4 10l5 5M4 10h10a6 6 0 010 12',
    check: 'M5 13l4 4L19 7',
    clock: 'M21 12a9 9 0 11-18 0 9 9 0 0118 0zM12 7v5l3 2',
    close: 'M6 6l12 12M6 18L18 6',
    link: 'M10 13a5 5 0 007 0l3-3a5 5 0 00-7-7l-2 2M14 11a5 5 0 00-7 0l-3 3a5 5 0 007 7l2-2'
  }.freeze

  # Decorative, monochrome icons: never depend on the OS's colour emoji font.
  def account_icon(name)
    tag.svg(class: 'w-5 h-5 inline-block align-middle mr-1', fill: 'none', stroke: 'currentColor',
            viewBox: '0 0 24 24', 'aria-hidden': true, focusable: false) do
      tag.path(d: ACCOUNT_ICON_PATHS.fetch(name), 'stroke-width': 1.8,
               'stroke-linecap': 'round', 'stroke-linejoin': 'round')
    end
  end

  def invoice_language_label(locale)
    { 'nl' => 'Nederlands', 'fr' => 'Français', 'de' => 'Deutsch', 'en' => 'English' }[locale.to_s] ||
      t('account.invoice_language_auto')
  end
end
