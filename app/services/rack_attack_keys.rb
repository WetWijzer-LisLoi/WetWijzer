# frozen_string_literal: true

# WW-SEC-02: what the auth rules in config/initializers/rack_attack.rb share.
# The rules call these at request time, so the module autoloads like any
# other.
module RackAttackKeys
  # Pages a visitor must always be able to open, even while their address is
  # throttled elsewhere: GET or HEAD of these exact paths, nothing else.
  ALWAYS_REACHABLE_PAGES = %w[/login /account /pricing].freeze

  # Email throttles key on a keyed digest of the normalized address, never
  # the address itself, so no email lands in a cache key.
  def self.email_discriminator(value)
    @email_discriminator_key ||= Rails.application.key_generator.generate_key('rack-attack-email v1', 32)
    email = value.is_a?(String) ? value.strip.downcase : ''
    OpenSSL::HMAC.hexdigest('SHA256', @email_discriminator_key, email)
  end

  # Address throttles, the repeated-offender ban and its counter key on a
  # keyed digest of request.ip as well, so no Rack::Attack key, ban entry or
  # cache file name holds a client address (WW-ABUSE-01, ABUSE-07). One digest
  # per request, kept in the env for the rules that follow.
  def self.ip_discriminator(request)
    request.env['wetwijzer.rack_attack.ip_discriminator'] ||= begin
      @ip_discriminator_key ||= Rails.application.key_generator.generate_key('rack-attack-ip v1', 32)
      OpenSSL::HMAC.hexdigest('SHA256', @ip_discriminator_key, request.ip.to_s)
    end
  end
end
