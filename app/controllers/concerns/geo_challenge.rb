# frozen_string_literal: true

require 'resolv'

# == GeoChallenge Concern
#
# Enforces a proof-of-work CAPTCHA challenge for visitors outside the EU.
# nginx GeoIP2 sets the X-Geo-EU header (1=EU, 0=non-EU).
#
# Skip conditions (no challenge required):
# - EU visitors (X-Geo-EU: 1)
# - Logged-in users
# - Valid geo_verified signed cookie (24h TTL)
# - Asset/health/API requests
# - Search engine crawlers
# - The geo-challenge pages themselves
#
module GeoChallenge
  extend ActiveSupport::Concern

  included do
    before_action :enforce_geo_challenge
  end

  private

  # Main gate: redirect non-EU visitors without a valid cookie to the challenge page
  def enforce_geo_challenge
    return if skip_geo_challenge?
    return if classic_host? # Classic is the no-JS fallback - allow non-EU access
    return if eu_visitor?
    return if geo_verified?
    return if logged_in?
    return if known_crawler?

    # Store the original URL so we can redirect back after solving
    cookies.signed[:geo_return_to] = {
      value: request.fullpath,
      expires: 10.minutes.from_now,
      httponly: true,
      secure: Rails.env.production?
    }

    Rails.logger.info("GeoChallenge: blocking non-EU visitor #{request.remote_ip} (#{request.headers['X-Geo-Country']}) UA=#{request.user_agent.to_s.truncate(80)} path=#{request.fullpath}")
    redirect_to geo_challenge_path, status: :see_other
  end

  # EU visitor based on nginx GeoIP2 header
  def eu_visitor?
    request.headers['X-Geo-EU'].to_s == '1'
  end

  # Belgian visitor - used for anonymous chatbot access (Belgian law = Belgian audience)
  def belgian_visitor?
    request.headers['X-Geo-Country'].to_s.upcase == 'BE'
  end

  # Valid signed cookie from a previous successful challenge
  def geo_verified?
    cookies.signed[:geo_verified].present?
  end

  # Known search engine crawlers - verified via reverse DNS to prevent UA spoofing
  # See: https://developers.google.com/search/docs/crawling-indexing/verifying-googlebot
  def known_crawler?
    ua = request.user_agent.to_s

    # Social media preview bots - UA-only check (low risk: they fetch single URLs for link cards)
    if ua.match?(/LinkedInBot|facebookexternalhit|Twitterbot|WhatsApp|Slackbot|Discordbot|Telegrambot/i)
      Rails.logger.debug("GeoChallenge: social preview bot bypass for #{request.remote_ip} UA=#{ua.truncate(60)}")
      return true
    end

    # Search engine crawlers - DNS-verified to prevent spoofing
    return false unless ua.match?(/Googlebot|bingbot|Slurp|DuckDuckBot|Applebot|AdsBot-Google/i)

    verified = verified_crawler_ip?(request.remote_ip)
    if verified
      Rails.logger.debug("GeoChallenge: DNS-verified crawler #{request.remote_ip} UA=#{ua.truncate(60)}")
    else
      Rails.logger.warn("GeoChallenge: SPOOFED crawler detected! IP=#{request.remote_ip} UA=#{ua.truncate(80)} - DNS verification failed")
    end
    verified
  end

  # Reverse DNS verification: resolve IP → hostname → IP round-trip
  # Only accepts IPs that resolve to known crawler domains
  VALID_CRAWLER_DOMAINS = %w[
    .googlebot.com .google.com .search.msn.com
    .crawl.yahoo.net .applebot.apple.com .duckduckgo.com
  ].freeze

  def verified_crawler_ip?(ip)
    Rails.cache.fetch("crawler_verified:#{ip}", expires_in: 24.hours) do
      hostname = Resolv.getname(ip)
      next false unless VALID_CRAWLER_DOMAINS.any? { |domain| hostname.end_with?(domain) }

      # Forward DNS to confirm hostname resolves back to the same IP
      forward_ip = Resolv.getaddress(hostname)
      forward_ip == ip
    rescue Resolv::ResolvError, Resolv::ResolvTimeout
      false
    end
  end

  # Paths and conditions that should never trigger the challenge
  def skip_geo_challenge?
    path = request.path.to_s.downcase

    # The challenge page itself
    return true if path.start_with?('/geo-challenge')

    # Static assets, health checks, API endpoints
    return true if path.start_with?('/assets/', '/packs/', '/health', '/robots', '/sitemap', '/favicon', '/altcha')

    # Admin panel (has its own auth), login/signup flows
    return true if path.start_with?('/admin')
    return true if path.start_with?('/login', '/signup', '/forgot-password', '/reset-password')

    # RSS/Atom feeds
    return true if path.end_with?('.xml', '.rss', '.atom', '.json')

    # Webhook/callback endpoints
    return true if path.start_with?('/webhooks/', '/callbacks/', '/api/')

    false
  end
end
