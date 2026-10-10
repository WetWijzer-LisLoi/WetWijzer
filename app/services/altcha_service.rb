# frozen_string_literal: true

# == AltchaService
#
# Self-hosted ALTCHA proof of work for the geo check (/geo-challenge): the
# client finds a number N such that SHA-256(salt + N) == challenge, and the
# server checks the answer against its own signature, without storing the
# challenge.
#
# F6 (2026-10-07): a solved payload used to verify forever and any number of
# times, so one solution, replayed, gave every bot a fresh 24-hour geo cookie.
# A geo proof is now, like the signup proof (SignupProofOfWork, WW-ABUSE-01):
#
# - short-lived: the expiry rides in the salt as ?expires=, as ALTCHA does,
#   and the signature covers the salt;
# - bound to this purpose: the signature is taken over the geo domain, so a
#   proof issued for anything else never verifies here;
# - one-time: verifying reserves the salt's nonce atomically
#   (AtomicCacheCounter), so a replay is refused, and so is any proof while
#   the cache cannot answer. A NullStore (the test default) turns the ledger
#   off, as it turns off the other limits.
#
# Protocol: https://altcha.org/docs/api/
#
# @example Generate a challenge
#   AltchaService.generate_challenge
#   # => { algorithm: "SHA-256", challenge: "...", salt: "<32 hex>?expires=<unix>", signature: "...", maxnumber: 100000 }
#
# @example Verify a solution (true once per issued challenge)
#   AltchaService.verify_solution(params[:altcha])
class AltchaService
  ALGORITHM = 'SHA-256'
  MAX_NUMBER = 100_000
  TTL = 10.minutes
  CLOCK_SKEW = 60
  MAX_PAYLOAD_BYTES = 2_048
  DOMAIN = 'geo-challenge:v1'
  SALT_FORMAT = /\A(?<nonce>\h{32})\?expires=(?<expires>\d{1,12})\z/
  STRING_FIELDS = %w[challenge salt signature].freeze

  class << self
    # A new challenge for the ALTCHA widget.
    # @return [Hash] algorithm, challenge, salt, signature, maxnumber
    def generate_challenge(now: Time.current)
      salt = "#{SecureRandom.hex(16)}?expires=#{(now + TTL).to_i}"
      challenge = OpenSSL::Digest::SHA256.hexdigest("#{salt}#{SecureRandom.random_number(MAX_NUMBER)}")
      {
        algorithm: ALGORITHM,
        challenge: challenge,
        salt: salt,
        signature: signature(challenge, salt),
        maxnumber: MAX_NUMBER
      }
    end

    # Verifies an ALTCHA solution payload (Base64-encoded JSON) and spends it.
    # @return [Boolean] true exactly once per issued, unexpired, solved challenge
    def verify_solution(payload, now: Time.current)
      data = decode(payload)
      return false unless data

      salt = SALT_FORMAT.match(data['salt'])
      return false unless salt && current?(Integer(salt[:expires], 10), now)
      return false unless solved?(data) && signed?(data)

      claim(salt[:nonce])
    rescue AtomicCacheCounter::Unavailable
      Rails.logger.warn('AltchaService: the one-time ledger is unavailable; the proof is refused')
      false
    end

    private

    # The atomic once-only step: the first claim of a nonce wins.
    def claim(nonce)
      return true if Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      !AtomicCacheCounter.try_reserve!("#{DOMAIN}:used:#{nonce}", limit: 1, expires_in: TTL + CLOCK_SKEW).nil?
    end

    def decode(payload)
      return nil unless payload.is_a?(String) && payload.present? && payload.bytesize <= MAX_PAYLOAD_BYTES

      data = JSON.parse(Base64.strict_decode64(payload))
      return nil unless data.is_a?(Hash) && data['algorithm'] == ALGORITHM
      return nil unless STRING_FIELDS.all? { |field| data[field].is_a?(String) }

      data
    rescue ArgumentError, JSON::ParserError
      nil
    end

    # Unexpired, and never further out than an issued challenge can be.
    def current?(expires, now)
      expires > now.to_i && expires <= (now + TTL).to_i + CLOCK_SKEW
    end

    def solved?(data)
      number = data['number']
      number.is_a?(Integer) && number.between?(0, MAX_NUMBER) &&
        secure_compare(OpenSSL::Digest::SHA256.hexdigest("#{data['salt']}#{number}"), data['challenge'])
    end

    def signed?(data)
      secure_compare(signature(data['challenge'], data['salt']), data['signature'])
    end

    def signature(challenge, salt)
      OpenSSL::HMAC.hexdigest('SHA256', hmac_key, [DOMAIN, challenge, salt].join('|'))
    end

    def hmac_key
      ENV.fetch('ALTCHA_HMAC_KEY') { Rails.application.secret_key_base[0..31] }
    end

    def secure_compare(expected, actual)
      ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end
  end
end
