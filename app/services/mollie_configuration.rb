# frozen_string_literal: true

require 'uri'

# Central, fail-closed configuration for Mollie payment callbacks.
#
# Mollie's classic payment webhook contains only a payment id. WetWijzer still
# fetches that payment from Mollie and verifies all stored attributes, while an
# opaque token in the callback URL prevents arbitrary callers from turning the
# endpoint into an unauthenticated Mollie API oracle.
class MollieConfiguration
  class ConfigurationError < StandardError; end

  PRODUCTION_WEBHOOK_HOSTS = %w[
    wetwijzer.be
    www.wetwijzer.be
    lisloi.be
    www.lisloi.be
    gesetzguide.be
    www.gesetzguide.be
    lexlibera.be
    www.lexlibera.be
  ].freeze
  STAGING_WEBHOOK_HOSTS = %w[
    staging.wetwijzer.be
    staging.lisloi.be
    staging.gesetzguide.be
    staging.lexlibera.be
  ].freeze
  WEBHOOK_TOKEN_PATTERN = /\A[A-Za-z0-9_-]{32,128}\z/

  class << self
    def payments_enabled?
      ENV['MOLLIE_PAYMENTS_ENABLED'] == 'true'
    end

    def configured?
      MollieApiClient.new.configured? &&
        valid_api_mode? &&
        valid_token_configuration? &&
        ENV['MOLLIE_WEBHOOK_BASE_URL'].present? &&
        valid_webhook_base_url?
    end

    def checkout_enabled?
      payments_enabled? && configured?
    end

    def webhook_url
      raise ConfigurationError, 'Mollie payments are not fully configured' unless configured?

      uri = parsed_webhook_base_url
      uri.path = '/webhooks/mollie'
      uri.query = URI.encode_www_form(token: ENV.fetch('MOLLIE_WEBHOOK_TOKEN'))
      uri.fragment = nil
      uri.to_s
    end

    def valid_webhook_token?(candidate)
      supplied = candidate.to_s
      return false unless valid_webhook_token_format?(supplied)

      configured_webhook_tokens.any? do |expected|
        supplied.bytesize == expected.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
      end
    end

    def locale_for(locale)
      {
        'nl' => 'nl_BE',
        'fr' => 'fr_BE',
        'de' => 'de_DE',
        'en' => 'en_GB'
      }.fetch(locale.to_s, 'nl_BE')
    end

    private

    def valid_api_mode?
      key = ENV.fetch('MOLLIE_API_KEY', '').strip
      if Rails.env.production?
        key.start_with?('live_')
      elsif Rails.env.staging? || Rails.env.test? || Rails.env.development?
        key.start_with?('test_')
      else
        false
      end
    end

    def valid_token_configuration?
      current = ENV.fetch('MOLLIE_WEBHOOK_TOKEN', '')
      previous = ENV.fetch('MOLLIE_WEBHOOK_TOKEN_PREVIOUS', '')
      valid_webhook_token_format?(current) &&
        (previous.blank? || valid_webhook_token_format?(previous))
    end

    def configured_webhook_tokens
      [
        ENV.fetch('MOLLIE_WEBHOOK_TOKEN', ''),
        ENV.fetch('MOLLIE_WEBHOOK_TOKEN_PREVIOUS', '')
      ].select { |token| valid_webhook_token_format?(token) }
    end

    def valid_webhook_token_format?(token)
      token.to_s.match?(WEBHOOK_TOKEN_PATTERN)
    end

    def valid_webhook_base_url?
      uri = parsed_webhook_base_url
      uri.is_a?(URI::HTTPS) &&
        uri.userinfo.nil? &&
        uri.query.nil? &&
        uri.fragment.nil? &&
        (uri.path.blank? || uri.path == '/') &&
        uri.port == 443 &&
        allowed_webhook_hosts.include?(uri.host.to_s.downcase)
    rescue URI::InvalidURIError
      false
    end

    def allowed_webhook_hosts
      if Rails.env.production?
        PRODUCTION_WEBHOOK_HOSTS
      elsif Rails.env.staging? || Rails.env.test? || Rails.env.development?
        STAGING_WEBHOOK_HOSTS
      else
        []
      end
    end

    def parsed_webhook_base_url
      URI.parse(ENV.fetch('MOLLIE_WEBHOOK_BASE_URL', ''))
    end
  end
end
