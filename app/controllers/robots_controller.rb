# frozen_string_literal: true

# Serves dynamic robots.txt based on the request hostname.
# Staging subdomains (staging.wetwijzer.be, staging.lisloi.be, staging.gesetzguide.be)
# are fully blocked from indexing. Production domains serve the standard rules.
class RobotsController < ApplicationController
  # No authentication, no layout, no CSRF
  skip_before_action :verify_authenticity_token, raise: false

  def show
    render plain: robots_content, content_type: 'text/plain'
  end

  private

  def robots_content
    if staging_host?
      staging_robots
    else
      production_robots
    end
  end

  def staging_robots
    <<~ROBOTS
      # Staging environment — do not index
      User-agent: *
      Disallow: /
    ROBOTS
  end

  def production_robots
    # Determine the canonical production domain from the request host
    domain = production_domain

    <<~ROBOTS
      # See https://www.robotstxt.org/robotstxt.html for documentation on how to use the robots.txt file

      User-agent: *
      Allow: /
      # Prevent deep pagination crawling (causes heavy DB load)
      Disallow: /laws?*page=
      Disallow: /laws.rss
      Disallow: /jurisprudence
      Disallow: /parliamentary_work?*page=
      Disallow: /rechters
      Disallow: /account
      Disallow: /admin
      Disallow: /checkout
      Disallow: /login
      Disallow: /signup

      # Block aggressive crawlers entirely
      User-agent: Amazonbot
      Disallow: /

      User-agent: MJ12bot
      Disallow: /

      User-agent: AhrefsBot
      Disallow: /

      User-agent: SemrushBot
      Disallow: /

      User-agent: DotBot
      Disallow: /

      User-agent: BLEXBot
      Disallow: /

      User-agent: PetalBot
      Disallow: /

      User-agent: Bytespider
      Disallow: /

      User-agent: GPTBot
      Disallow: /

      User-agent: ClaudeBot
      Disallow: /

      User-agent: CCBot
      Disallow: /

      User-agent: OAI-SearchBot
      Disallow: /

      User-agent: Thinkbot
      Disallow: /

      User-agent: meta-externalagent
      Disallow: /

      User-agent: Amzn-SearchBot
      Disallow: /

      User-agent: DataForSeoBot
      Disallow: /

      # Sitemap for this domain only (cross-domain hreflang is handled inside the sitemap)
      Sitemap: https://#{domain}/sitemap.xml
    ROBOTS
  end

  # Returns the canonical production domain for the current request.
  # Falls back to wetwijzer.be if the host doesn't match any known domain.
  def production_domain
    host = effective_host.to_s.downcase
    if host.include?('lisloi')
      'lisloi.be'
    elsif host.include?('gesetzguide')
      'gesetzguide.be'
    else
      'wetwijzer.be'
    end
  end
end
