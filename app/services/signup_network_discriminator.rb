# frozen_string_literal: true

require 'ipaddr'

# WW-ABUSE-01 (ABUSE-04): the network a signup comes from, as a keyed HMAC
# and never as a printable address. IPv4 collapses to its /24 and IPv6 to its
# /64 (one household, office or provider allocation each); an IPv4-mapped
# IPv6 address counts as the IPv4 it maps; a value that does not parse keeps
# its own exact bucket, so malformed input never pools into one shared bucket
# and never escapes counting. The input is request.remote_ip, which the
# loopback-only trusted proxy boundary (config/application.rb) makes
# unspoofable by a forwarded header.
#
# The key is derived from secret_key_base under its own salt and the message
# carries a versioned domain label, so the value is useless outside this
# counter and changes completely if the scheme does. Only the HMAC leaves this
# class: counters key on it, and telemetry may log it.
class SignupNetworkDiscriminator
  DOMAIN = 'signup-network:v1'
  EXACT_DOMAIN = 'signup-address:v1'
  KEY_SALT = 'signup-network-discriminator v1'
  IPV4_PREFIX = 24
  IPV6_PREFIX = 64

  def self.for(remote_ip)
    new.discriminator(remote_ip)
  end

  # The exact address, for the per-address limit: the same keyed scheme
  # under its own domain label, so an address bucket never equals a network
  # bucket. An IPv4-mapped IPv6 address is its IPv4 address.
  def self.exact_for(remote_ip)
    new.exact_discriminator(remote_ip)
  end

  def discriminator(remote_ip)
    family, network = canonical_network(remote_ip.to_s.strip)
    OpenSSL::HMAC.hexdigest('SHA256', key, "#{DOMAIN}:#{family}:#{network}")
  end

  def exact_discriminator(remote_ip)
    family, address = canonical_address(remote_ip.to_s.strip)
    OpenSSL::HMAC.hexdigest('SHA256', key, "#{EXACT_DOMAIN}:#{family}:#{address}")
  end

  private

  def canonical_network(value)
    address = IPAddr.new(value)
    address = address.native if address.ipv4_mapped?
    if address.ipv4?
      ['ipv4', "#{address.mask(IPV4_PREFIX)}/#{IPV4_PREFIX}"]
    else
      ['ipv6', "#{address.mask(IPV6_PREFIX)}/#{IPV6_PREFIX}"]
    end
  rescue ArgumentError # IPAddr::Error included
    ['exact', value.downcase]
  end

  def canonical_address(value)
    address = IPAddr.new(value)
    address = address.native if address.ipv4_mapped?
    [address.ipv4? ? 'ipv4' : 'ipv6', address.to_s]
  rescue ArgumentError # IPAddr::Error included
    ['exact', value.downcase]
  end

  def key
    @key ||= Rails.application.key_generator.generate_key(KEY_SALT, 32)
  end
end
