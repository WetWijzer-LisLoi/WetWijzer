# frozen_string_literal: true

# WW-ABUSE-01 (ABUSE-05): the registration proof of work. It reuses the
# self-hosted ALTCHA widget and its SHA-256 puzzle, but not the stateless,
# replayable contract of the geo check (AltchaService). A signup proof is:
#
# - short-lived: the expiry rides in the salt as ?expires=, as ALTCHA does;
# - bound: its signature, under a key of its own, covers the signup purpose,
#   the network discriminator and the normalized-email digest it was issued
#   for, so a proof solved for another purpose, network or address (including
#   a geo-check solution) never verifies;
# - one-time: consuming it reserves its random nonce atomically
#   (AtomicCacheCounter), so it authorizes one registration attempt and a
#   replay authorizes none.
#
# Nothing here is logged. The payload is filtered from request logs
# (config/initializers/filter_parameter_logging.rb) and never reaches account
# or activity metadata.
class SignupProofOfWork
  ALGORITHM = 'SHA-256'
  MAX_NUMBER = 100_000
  TTL = 10.minutes
  CLOCK_SKEW = 60
  MAX_PAYLOAD_BYTES = 2_048
  DOMAIN = 'signup-proof:v1'
  KEY_SALT = 'signup-proof-of-work v1'
  SALT_FORMAT = /\A(?<nonce>\h{32})\?expires=(?<expires>\d{1,12})\z/
  STRING_FIELDS = %w[challenge salt signature].freeze

  class << self
    # The ALTCHA challenge for the widget's challengejson attribute.
    def issue(network:, email_digest:, now: Time.current)
      salt = "#{SecureRandom.hex(16)}?expires=#{(now + TTL).to_i}"
      challenge = OpenSSL::Digest::SHA256.hexdigest("#{salt}#{SecureRandom.random_number(MAX_NUMBER)}")
      {
        algorithm: ALGORITHM,
        challenge: challenge,
        salt: salt,
        signature: signature(challenge, salt, network, email_digest),
        maxnumber: MAX_NUMBER
      }
    end

    # :ok exactly once per issued proof; otherwise :missing, :malformed,
    # :expired, :invalid or :replayed. Raises AtomicCacheCounter::Unavailable
    # when the one-time ledger cannot be written, and the caller denies.
    def consume!(payload, network:, email_digest:, now: Time.current)
      return :missing if payload.blank?

      data = decode(payload)
      return :malformed unless data

      salt = SALT_FORMAT.match(data['salt'])
      return :malformed unless salt
      return :expired unless current?(Integer(salt[:expires], 10), now)
      return :invalid unless solved?(data) && signed?(data, network, email_digest)
      return :replayed unless claim(salt[:nonce])

      :ok
    end

    private

    # The atomic once-only step: the first claim of a nonce wins.
    def claim(nonce)
      AtomicCacheCounter.try_reserve!("#{DOMAIN}:used:#{nonce}", limit: 1, expires_in: TTL + CLOCK_SKEW)
    end

    def decode(payload)
      return nil unless payload.is_a?(String) && payload.bytesize <= MAX_PAYLOAD_BYTES

      data = JSON.parse(Base64.strict_decode64(payload))
      return nil unless data.is_a?(Hash) && data['algorithm'] == ALGORITHM
      return nil unless STRING_FIELDS.all? { |field| data[field].is_a?(String) }

      data
    rescue ArgumentError, JSON::ParserError
      nil
    end

    # Unexpired, and never further out than an issued proof can be.
    def current?(expires, now)
      expires > now.to_i && expires <= (now + TTL).to_i + CLOCK_SKEW
    end

    def solved?(data)
      number = data['number']
      number.is_a?(Integer) && number.between?(0, MAX_NUMBER) &&
        secure_compare(OpenSSL::Digest::SHA256.hexdigest("#{data['salt']}#{number}"), data['challenge'])
    end

    def signed?(data, network, email_digest)
      secure_compare(signature(data['challenge'], data['salt'], network, email_digest), data['signature'])
    end

    def signature(challenge, salt, network, email_digest)
      OpenSSL::HMAC.hexdigest('SHA256', key, [DOMAIN, challenge, salt, network, email_digest].join('|'))
    end

    def key
      @key ||= Rails.application.key_generator.generate_key(KEY_SALT, 32)
    end

    def secure_compare(expected, actual)
      ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end
  end
end
