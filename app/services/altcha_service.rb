# frozen_string_literal: true

# == AltchaService
#
# Self-hosted ALTCHA proof-of-work challenge generation and verification.
# Uses HMAC-SHA256 to create challenges that require the client to find
# a number N such that SHA-256(salt + N) == challenge.
#
# Protocol: https://altcha.org/docs/api/
#
# @example Generate a challenge
#   challenge = AltchaService.generate_challenge
#   # => { algorithm: "SHA-256", challenge: "abc...", salt: "xyz...", signature: "sig...", maxnumber: 100000 }
#
# @example Verify a solution
#   AltchaService.verify_solution(params[:altcha])
#   # => true/false
#
class AltchaService
  ALGORITHM = 'SHA-256'
  MAX_NUMBER = 100_000

  class << self
    # Generates a new challenge for the ALTCHA widget.
    # @return [Hash] Challenge payload with algorithm, challenge, salt, signature, maxnumber
    def generate_challenge
      secret = hmac_key
      salt = SecureRandom.hex(16)
      number = SecureRandom.random_number(MAX_NUMBER)

      # The challenge is SHA-256(salt + number)
      challenge = OpenSSL::Digest::SHA256.hexdigest("#{salt}#{number}")

      # Sign the challenge with HMAC so we can verify it later without storage
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, challenge)

      {
        algorithm: ALGORITHM,
        challenge: challenge,
        salt: salt,
        signature: signature,
        maxnumber: MAX_NUMBER
      }
    end

    # Verifies an ALTCHA solution payload (Base64-encoded JSON).
    # @param payload [String] Base64-encoded JSON from the altcha-widget
    # @return [Boolean] true if valid
    def verify_solution(payload)
      return false if payload.blank?

      data = JSON.parse(Base64.decode64(payload))

      algorithm = data['algorithm']
      challenge = data['challenge']
      salt = data['salt']
      number = data['number']
      signature = data['signature']

      return false unless algorithm == ALGORITHM
      return false if challenge.blank? || salt.blank? || number.nil? || signature.blank?

      # Recompute: SHA-256(salt + number) must equal challenge
      expected_challenge = OpenSSL::Digest::SHA256.hexdigest("#{salt}#{number}")
      return false unless secure_compare(expected_challenge, challenge)

      # Verify HMAC signature
      expected_signature = OpenSSL::HMAC.hexdigest('SHA256', hmac_key, challenge)
      secure_compare(expected_signature, signature)
    rescue JSON::ParserError, ArgumentError => e
      Rails.logger.warn("AltchaService: invalid payload - #{e.message}")
      false
    end

    private

    def hmac_key
      ENV.fetch('ALTCHA_HMAC_KEY') { Rails.application.secret_key_base[0..31] }
    end

    def secure_compare(expected, actual)
      ActiveSupport::SecurityUtils.secure_compare(expected, actual)
    end
  end
end
