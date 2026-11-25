# frozen_string_literal: true

require 'erb'
require 'uri'

# Sol 2026-11-25 09:44:12Z: after repeated sign-in attempts the admin login showed the throttled responder's JSON as the
# page. A browser navigation now gets a short page in the site's language with the time from which it may try again
# (Brussels time) and a way back. API clients and scripts keep the JSON body; the limits and the RateLimit and
# Retry-After headers stay as they are.
# Sol 11:19:37Z: a navigation is told by what the browser says, not by a substring. Outside /api/ and without the XHR
# header, the request must prefer HTML (text/html listed with a q above 0, no other specific type ranked above it), and
# its fetch metadata must be a navigation (Sec-Fetch-Mode: navigate) or Turbo's own request (Turbo renders the page in
# place of a visit or a form's response); a script's fetch keeps the JSON even when it accepts HTML. A browser that
# sends no fetch metadata is judged by its Accept header alone. The way back is a path that resolves to this origin.
module RackAttackThrottledPage
  TIME_ZONE = 'Europe/Brussels'
  # Types a page answers as well as text/html does: no reason to prefer JSON
  HTML_TYPES = %w[text/html application/xhtml+xml text/vnd.turbo-stream.html].freeze
  TEXT = {
    'en' => { title: 'Too many attempts', try_again: 'You can try again from %<time>s (Brussels time).', back: 'Back' },
    'nl' => { title: 'Te veel pogingen', try_again: 'U kunt het opnieuw proberen vanaf %<time>s (Brusselse tijd).',
              back: 'Terug' },
    'fr' => { title: 'Trop de tentatives', try_again: 'Vous pourrez réessayer à partir de %<time>s (heure de Bruxelles).',
              back: 'Retour' },
    'de' => { title: 'Zu viele Versuche', try_again: 'Sie können es ab %<time>s (Brüsseler Zeit) erneut versuchen.',
              back: 'Zurück' }
  }.freeze

  module_function

  # The 429 response of Rack::Attack's throttled_responder for a browser navigation, with its headers and an HTML
  # body; nil for an API client or a script, which keep the JSON body
  def response_for(request, headers, reset:, now:)
    return nil unless browser_navigation?(request)

    [429, headers.merge('Content-Type' => 'text/html; charset=utf-8'), [html(request, reset, now: now)]]
  end

  def browser_navigation?(request)
    return false if request.path.start_with?('/api/') || request.xhr? || !html_preferred?(request)

    mode = request.get_header('HTTP_SEC_FETCH_MODE').to_s.strip.downcase
    mode.empty? || mode == 'navigate' || turbo_request?(request)
  end

  # Turbo marks every request it makes, frames included, and asks streams for its forms
  def turbo_request?(request)
    request.get_header('HTTP_X_TURBO_REQUEST_ID').present? || request.get_header('HTTP_TURBO_FRAME').present? ||
      accept_ranges(request).any? { |type, weight| type == 'text/vnd.turbo-stream.html' && weight.positive? }
  end

  def html_preferred?(request)
    ranges = accept_ranges(request)
    html = ranges.filter_map { |type, weight| weight if type == 'text/html' }.max
    return false unless html&.positive?

    other = ranges.reject { |type, _weight| HTML_TYPES.include?(type) || type.end_with?('/*') }.map(&:last).max
    other.nil? || html >= other
  end

  # [type, q] for each media range of the Accept header; a range whose q cannot be read is left out
  def accept_ranges(request)
    request.get_header('HTTP_ACCEPT').to_s.split(',').filter_map do |range|
      type, *parameters = range.split(';').map(&:strip)
      next if type.blank?

      q = parameters.filter_map { |parameter| parameter[/\Aq[[:space:]]*=[[:space:]]*(\S+)\z/i, 1] }.first
      weight = q.nil? ? 1.0 : Float(q, exception: false)
      [type.downcase, weight] if weight
    end
  end

  def html(request, reset_epoch, now: Time.now)
    language = language_for(request)
    words = TEXT.fetch(language)
    message = format(words[:try_again], time: time_text(reset_epoch, now))
    back = ERB::Util.html_escape(back_path(request))
    <<~HTML
      <!DOCTYPE html>
      <html lang="#{language}">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{words[:title]}</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 80px auto; padding: 0 16px; background: #f5f5f5; color: #333; }
          main { background: #fff; padding: 32px; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
          h1 { margin-top: 0; font-size: 22px; }
          p { line-height: 1.6; }
          a { color: #1d4ed8; }
        </style>
      </head>
      <body>
        <main>
          <h1>#{words[:title]}</h1>
          <p>#{message}</p>
          <p><a href="#{back}">#{words[:back]}</a></p>
        </main>
      </body>
      </html>
    HTML
  end

  # The admin interface is English; a public site speaks its own language
  def language_for(request)
    return 'en' if request.path.start_with?('/admin')

    SiteBrand::LOCALES.fetch(SiteBrand.resolve_request(request), 'nl')
  end

  # The reset in Brussels time: the clock time on the same day, with the date on another day
  def time_text(reset_epoch, now)
    reset = Time.at(reset_epoch).in_time_zone(TIME_ZONE)
    reset.strftime(reset.to_date == Time.at(now).in_time_zone(TIME_ZONE).to_date ? '%H:%M' : '%d-%m-%Y %H:%M')
  end

  # Back to the page the request came from when that is this origin, else the page itself for a GET, else the admin
  # sign-in for the admin or the home page. Each candidate, from the referrer or the request, must be a local path.
  def back_path(request)
    [same_origin_referer(request), (request.fullpath if request.get?)].each do |candidate|
      return candidate if local_path?(candidate)
    end
    request.path.start_with?('/admin') ? '/admin/login' : '/'
  end

  def same_origin_referer(request)
    uri = URI.parse(request.referer.to_s)
    return nil unless same_origin?(request, uri)

    uri.query ? "#{uri.path}?#{uri.query}" : uri.path
  rescue URI::Error
    nil
  end

  # A path a browser keeps on this origin: one leading slash not followed by a second slash or a backslash (a browser
  # reads "//host/x" and "/\host" as another host's address), and no space or control character (a browser drops tabs
  # and newlines from a URL, which could bring such slashes together)
  def local_path?(path)
    path.is_a?(String) && path.match?(%r{\A/(?![/\\])[^[:space:][:cntrl:]]*\z})
  end

  def same_origin?(request, uri)
    uri.scheme.to_s.casecmp?(request.scheme) && uri.host.to_s.casecmp?(request.host) && uri.port == request.port
  end
end
