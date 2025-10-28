# frozen_string_literal: true

# Shared logic for detecting the effective host from request headers
module HostDetection
  extend ActiveSupport::Concern

  private

  # Returns the effective hostname, respecting reverse proxy headers
  def effective_host
    host_from_rfc_forwarded || host_from_x_forwarded || request.host
  end

  def host_from_rfc_forwarded
    rfc_forwarded = request.headers['Forwarded'].to_s
    rfc_host = rfc_forwarded[/\bhost=([^;]+)/i, 1].to_s.delete('"')
    strip_port(rfc_host.presence)
  end

  def host_from_x_forwarded
    xf_host = request.headers['X-Forwarded-Host'].to_s.split(',').first
    strip_port(xf_host.presence)
  end

  def strip_port(host)
    host&.split(':')&.first
  end
end
