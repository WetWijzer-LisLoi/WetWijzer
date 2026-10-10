# frozen_string_literal: true

require 'ipaddr'

# WW-PRIV-04: one privacy-safe format for security and audit log lines.
#
#   [security] event=<name> path=<route path, no query> ip=<network>/24
#   ip_key=<keyed pseudonym> ua=<family> user=<account id> <field>=<value> ...
#
# The client address is reduced to its network (IPv4 /24, IPv6 /48) plus a
# keyed pseudonym of the full address, so repeated events from one address
# still correlate as abuse evidence without the address being written. The
# user agent is reduced to a family, an email to a keyed pseudonym; a query
# string is never written. Every value becomes one bounded token: control
# characters and line separators turn into '?', whitespace into '_', so no
# request value can end the line or forge another record.
#
# Retention: these lines go to log/production.log, rotated at 50 MB with five
# files kept (config/environments/production.rb), and to the journal, which
# keeps what journald is configured to keep. See docs/ops/open-items.md.
module SecurityLog
  MAX_VALUE = 120
  KEY_SALT = 'security-log pseudonym v1'
  UNSAFE = /[[:cntrl:]\u0085  ]/
  UA_FAMILIES = [
    [/bot|crawl|spider|slurp|facebookexternalhit|whatsapp|preview/i, 'bot'],
    [%r{curl|wget|python|httpclient|okhttp|go-http|java/}i, 'tool'],
    [%r{edg/}i, 'edge'],
    [/chrome|crios/i, 'chrome'],
    [/firefox|fxios/i, 'firefox'],
    [/safari/i, 'safari']
  ].freeze

  module_function

  def line(event, request: nil, user: nil, **fields)
    parts = ["[security] event=#{clean(event)}"]
    if request
      parts << "path=#{clean(request.path)}" << "ip=#{network(request.remote_ip)}"
      parts << "ip_key=#{pseudonym(request.remote_ip)}" << "ua=#{ua_family(request.user_agent)}"
    end
    parts << "user=#{clean(user.respond_to?(:id) ? user.id : user)}" unless user.nil?
    fields.each { |name, value| parts << "#{clean(name)}=#{clean(value)}" }
    parts.join(' ')
  end

  def info(event, **)
    Rails.logger.info(line(event, **))
  end

  def warn(event, **)
    Rails.logger.warn(line(event, **))
  end

  # A keyed digest that correlates without being readable (an address, an
  # email given at a failed admin sign-in).
  def pseudonym(value)
    return '-' if value.blank?

    OpenSSL::HMAC.hexdigest('SHA256', key, value.to_s.strip.downcase)[0, 12]
  end

  def network(ip)
    address = IPAddr.new(ip.to_s)
    address.ipv4? ? "#{address.mask(24)}/24" : "#{address.mask(48)}/48"
  rescue IPAddr::Error
    '-'
  end

  def ua_family(user_agent)
    return '-' if user_agent.blank?

    UA_FAMILIES.find { |pattern, _family| user_agent.match?(pattern) }&.last || 'other'
  end

  def clean(value)
    value.to_s.gsub(UNSAFE, '?').gsub(/\s+/, '_')[0, MAX_VALUE].presence || '-'
  end

  def key
    @key ||= Rails.application.key_generator.generate_key(KEY_SALT, 32)
  end
end
