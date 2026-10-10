# frozen_string_literal: true

# Public account creation is available only from Belgium. This is independent
# of the site's browsing challenge, its cookie and the signup proof of work.
#
# nginx is the public edge: GeoIP2 looks up $remote_addr and every public proxy
# location OVERWRITES X-Geo-Country with the resulting ISO country. Puma binds
# to loopback on Linux. Trust that header only from the raw loopback transport
# peer, never request.remote_ip (the visitor) or a client forwarding header.
# Missing/unknown/malformed countries and untrusted peers all fail closed.
class RegistrationCountryPolicy
  def initialize(request:)
    @request = request
  end

  def allowed?
    # The admin ingress does not stamp GeoIP headers. Its nginx-stamped Host
    # must never turn a client-supplied country into trusted public signup.
    return false if admin_host?

    peer = @request.get_header('REMOTE_ADDR')
    peer.is_a?(String) && ClientAddressBoundary.trusted_proxy?(peer) &&
      @request.get_header('HTTP_X_GEO_COUNTRY') == 'BE'
  end

  private

  def admin_host?
    # Use raw Host, which nginx overwrites, rather than request.host, which
    # can follow X-Forwarded-Host. A forged forwarding header cannot hide admin.
    host = @request.get_header('HTTP_HOST').to_s.downcase.split(':', 2).first
    host.to_s.split('.').include?('admin')
  end
end
