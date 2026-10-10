# frozen_string_literal: true

require 'uri'

# WW-SEC-11: a link built from an imported record goes out only to an
# official source. Rails escapes attribute syntax but keeps a `javascript:`
# URL or any foreign destination, so a hostile or broken row in the chamber
# database could otherwise put a script link or another site behind "PDF".
# A sample of 7,668 production links (2026-10-07) were all https on
# www.dekamer.be or www.senate.be and all pass.
module OfficialSourceUrl
  PARLIAMENT_HOSTS = %w[
    www.dekamer.be dekamer.be www.lachambre.be lachambre.be
    www.senate.be senate.be www.senaat.be senaat.be www.senat.be senat.be
  ].freeze

  # WW-SEC-15 refinement: the Justel link the updater scrapes into repeal_info.
  JUSTEL_HOSTS = %w[www.ejustice.just.fgov.be ejustice.just.fgov.be].freeze

  # The URL when it is http(s) on an official parliament host, else nil.
  def self.parliamentary(url)
    official(url, PARLIAMENT_HOSTS)
  end

  # The URL when it is http(s) on the official Justel host, else nil.
  def self.justel(url)
    official(url, JUSTEL_HOSTS)
  end

  def self.official(url, hosts)
    uri = URI.parse(url.to_s.strip)
    return nil unless %w[http https].include?(uri.scheme&.downcase) && hosts.include?(uri.host&.downcase)

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
  private_class_method :official
end
