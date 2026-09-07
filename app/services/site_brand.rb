# frozen_string_literal: true

# The single vocabulary for which PRODUCT BRAND a request arrived on:
# WetWijzer, LisLoi, GesetzGuide or LexLibera. Auth attribution, admin labels,
# exports and their tests all speak through this registry - nothing else may
# invent a brand code or render a stored one raw.
#
# WHY request.host AND ONLY request.host (audited 2026-09-01 on the live nginx
# config, then corrected by a failing test): Rails' request.host itself reads
# X-Forwarded-Host at the Rack level when the header is present, so its value
# is trustworthy here for exactly one reason - every nginx proxy location that
# reaches Puma OVERWRITES X-Forwarded-Host (and Host) with $host, and Rails
# Host Authorization validates that header against config.hosts besides. The
# RFC `Forwarded` header, by contrast, passes through nginx UNTOUCHED, is
# validated by nobody, and is never consulted by request.host - but
# HostDetection#effective_host PREFERS it, which lets any client choose the
# brand with one request header. Durable attribution must never be built on
# effective_host, and any future bypass of nginx's header rewrite would
# reopen X-Forwarded-Host as an attribution input - the staging/nginx proof
# in the rollout plan exists to catch precisely that.
#
# WHY an exact registry and not config.hosts: production authorizes wildcard
# subdomains (/.*\.wetwijzer\.be/ etc.), so `evil.wetwijzer.be` and
# `classic.www.wetwijzer.be` are host-AUTHORIZED without being product hosts.
# Authorization is not identity. Anything not in the registry resolves to nil,
# and nil is stored as NULL - never silently rewritten to WetWijzer.
#
# WHY the lexliber/lexlibera.eu aliases are ABSENT: nginx 301s lexliber.be,
# www.lexliber.be, lexliber.eu, www.lexliber.eu, lexlibera.eu and
# www.lexlibera.eu straight to https://lexlibera.be, so no registration or
# login can ever arrive on them over HTTPS. A name that cannot carry the event
# does not belong in the registry; if one ever appears anyway it resolves nil,
# which is the honest answer.
class SiteBrand
  KEYS = %w[wetwijzer lisloi gesetzguide lexlibera].freeze

  LABELS = {
    'wetwijzer' => 'WetWijzer',
    'lisloi' => 'LisLoi',
    'gesetzguide' => 'GesetzGuide',
    'lexlibera' => 'LexLibera'
  }.freeze

  # Display-only derivations. Locale is NOT brand: a user may browse WetWijzer
  # in French; these exist for labels and links, never for attribution input.
  LOCALES = {
    'wetwijzer' => 'nl',
    'lisloi' => 'fr',
    'gesetzguide' => 'de',
    'lexlibera' => 'en'
  }.freeze

  CANONICAL_DOMAINS = {
    'wetwijzer' => 'wetwijzer.be',
    'lisloi' => 'lisloi.be',
    'gesetzguide' => 'gesetzguide.be',
    'lexlibera' => 'lexlibera.be'
  }.freeze

  # The reviewed product hostnames, exactly. apex serves the product; classic.
  # serves the no-JS layout; www. 301s to apex and staging.* is currently not
  # served, but both are unambiguous product names under our control, so if a
  # request ever arrives on them the attribution is still true.
  HOSTS = KEYS.each_with_object({}) do |key, registry|
    domain = CANONICAL_DOMAINS.fetch(key)
    ["#{domain}", "www.#{domain}", "classic.#{domain}", "staging.#{domain}"].each do |host|
      registry[host] = key
    end
  end.freeze

  # RFC 1035 caps a hostname at 253 octets; anything longer is garbage and
  # gets no further reading.
  MAX_HOST_LENGTH = 253

  UNKNOWN_LABEL = 'Unknown'

  class << self
    # @param host [Object] a hostname as the server saw it (request.host)
    # @return [String, nil] canonical brand code, or nil for anything else.
    #   Never returns the input; never raises on hostile input.
    def resolve_host(host)
      return nil unless host.is_a?(String)
      return nil if host.length > MAX_HOST_LENGTH || host.empty?

      candidate = host.downcase
      # Port BEFORE trailing dot: 'lexlibera.be.:8443' must shed the port
      # first or the dot survives behind it - the order a failing test chose.
      candidate = candidate.sub(/:\d{1,5}\z/, '') # legal port suffix
      candidate = candidate.delete_suffix('.')    # trailing-dot FQDN spelling
      # A "host" carrying a path, credentials, whitespace, brackets or another
      # colon is not a hostname. Refuse rather than guess.
      return nil if candidate.match?(%r{[/@\s\[\]:]})

      HOSTS[candidate]
    end

    # The request boundary. Deliberately request.host - see the header comment
    # for why effective_host must not be used here.
    def resolve_request(request)
      resolve_host(request.host)
    end

    # For values INSIDE the application (params never reach this): nil-safe on
    # genuinely absent input, loud on anything else. An invalid internal code
    # is a programming error upstream, and silently rewriting it to nil would
    # bury exactly the bug this vocabulary exists to prevent.
    # @return [String, nil]
    def normalize_code(value)
      return nil if value.nil?

      code = value.to_s.strip
      return nil if code.empty?
      return code if KEYS.include?(code)

      raise ArgumentError, "not a canonical site brand code: #{code.inspect[0, 40]}"
    end

    # Safe for any stored value, including hostile or legacy garbage: a known
    # code gets its label, everything else is the one word Unknown. Never
    # echoes the input.
    def label_for(value)
      LABELS.fetch(value.to_s) { UNKNOWN_LABEL }
    end

    def locale_for(value)
      LOCALES[value.to_s]
    end

    def canonical_domain_for(value)
      CANONICAL_DOMAINS[value.to_s]
    end
  end
end
