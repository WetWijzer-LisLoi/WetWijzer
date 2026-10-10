# frozen_string_literal: true

# WW-ABUSE-01 (ABUSE-04): the client address boundary.
#
# nginx is the public edge and the only trusted proxy: Puma listens on
# loopback, and nginx sets X-Forwarded-For to the peer it accepted. Nothing
# else may name the client address that the application records and its
# limits count (Rails' request.remote_ip, and Rack's request.ip, which
# Rack::Attack keys on):
#
# 1. Rack reads X-Forwarded-For only. By default Rack 3 prefers an RFC 7239
#    Forwarded header, and Rails' remote_ip takes its chain from Rack. nginx
#    never sets Forwarded but passes a client's through unchanged, so until
#    this boundary any client could choose its own address (verified on
#    production on 2026-10-07 with a documentation address).
# 2. Rails and Rack trust loopback only, not every private range (the
#    default), so a Docker bridge peer, or a private-range client behind
#    nginx, counts as itself.
# 3. Middleware, first in the stack, drops the forwarding headers our edge
#    never sets (Forwarded, Client-IP) and drops X-Forwarded-For when the peer
#    is not a trusted proxy. Rails' remote_ip honours X-Forwarded-For whatever
#    the peer, so a client reaching Puma directly would otherwise choose its
#    address as well.
require 'ipaddr'

module ClientAddressBoundary
  TRUSTED_PROXIES = [IPAddr.new('127.0.0.0/8'), IPAddr.new('::1')].freeze
  CLIENT_ONLY_HEADERS = %w[HTTP_FORWARDED HTTP_CLIENT_IP].freeze
  FORWARDED_FOR = 'HTTP_X_FORWARDED_FOR'

  def self.trusted_proxy?(address)
    TRUSTED_PROXIES.any? { |range| range.include?(address) }
  rescue ArgumentError # IPAddr::Error included
    false
  end

  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      CLIENT_ONLY_HEADERS.each { |name| env.delete(name) }
      env.delete(FORWARDED_FOR) unless ClientAddressBoundary.trusted_proxy?(env['REMOTE_ADDR'])
      @app.call(env)
    end
  end
end

# Read when the middleware stack is built, after the initializers.
Rails.application.config.action_dispatch.trusted_proxies = ClientAddressBoundary::TRUSTED_PROXIES
Rack::Request.forwarded_priority = [:x_forwarded]
Rack::Request.ip_filter = ->(ip) { ClientAddressBoundary.trusted_proxy?(ip) }

Rails.application.config.middleware.insert_before 0, ClientAddressBoundary::Middleware
