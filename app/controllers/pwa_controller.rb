# frozen_string_literal: true

# == PWA Controller
#
# Serves the Progressive Web App plumbing so the site can be installed to a
# phone's home screen and launched full-screen (no browser chrome):
#   - GET /manifest.webmanifest  -> the web app manifest (locale/domain-aware)
#   - GET /offline               -> minimal fallback page shown when offline
#
# The service worker itself is served as a STATIC file (public/sw.js), because a
# controller returning text/javascript trips Rails' cross-origin-JS guard
# (InvalidCrossOriginRequest -> 422). Manifest + offline are public GETs, chosen
# per domain via I18n.locale (nl=wetwijzer, fr=lisloi, de=gesetzguide,
# en=lexlibera), mirroring FaviconsController.
class PwaController < ApplicationController
  def manifest
    loc = pwa_locale
    name = helpers.site_name
    render json: {
      name: name,
      short_name: name,
      lang: loc,
      dir: 'ltr',
      description: t(:meta_description),
      start_url: '/',
      scope: '/',
      id: '/',
      display: 'standalone',
      orientation: 'portrait',
      background_color: '#ffffff',
      theme_color: '#0f172a',
      categories: %w[reference government education],
      icons: [
        { src: "/pwa/icon-#{loc}-192.png", sizes: '192x192', type: 'image/png', purpose: 'any' },
        { src: "/pwa/icon-#{loc}-512.png", sizes: '512x512', type: 'image/png', purpose: 'any' },
        { src: "/pwa/icon-#{loc}-maskable.png", sizes: '512x512', type: 'image/png', purpose: 'maskable' }
      ]
    }, content_type: 'application/manifest+json'
  end

  def offline
    render template: 'pwa/offline', layout: false
  end

  private

  def pwa_locale
    loc = I18n.locale.to_s
    %w[nl fr de en].include?(loc) ? loc : 'nl'
  end
end
