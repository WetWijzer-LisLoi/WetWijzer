# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require 'json'
require 'net/http'
require 'openssl'
require 'timeout'
require 'uri'

# Minimal Mollie API v2 client.
#
# The client intentionally uses a fixed API origin and exposes only the
# operations WetWijzer needs. It never logs request/response bodies, since those
# can contain customer data, payment metadata, or credentials.
class MollieApiClient
  API_HOST = 'api.mollie.com'
  API_PORT = 443
  API_PREFIX = '/v2'

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15
  WRITE_TIMEOUT = 10

  CHECKOUT_HOSTS = %w[www.mollie.com].freeze
  VALID_SEQUENCE_TYPES = %w[oneoff first recurring].freeze
  MAX_IDEMPOTENCY_KEY_LENGTH = 255
  API_KEY_PATTERN = /\A(?:test|live)_[A-Za-z0-9]{24,}\z/

  RESOURCE_ID_PATTERNS = {
    customer: /\Acst_[A-Za-z0-9]+\z/,
    mandate: /\Amdt_[A-Za-z0-9]+\z/,
    payment: /\Atr_[A-Za-z0-9]+\z/,
    subscription: /\Asub_[A-Za-z0-9]+\z/
  }.freeze

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ValidationError < Error; end
  class NetworkError < Error; end
  class InvalidResponseError < Error; end

  class ApiError < Error
    attr_reader :http_status

    def initialize(http_status)
      @http_status = http_status
      super("Mollie API request failed (HTTP #{http_status})")
    end

    def retryable?
      http_status == 429 || http_status >= 500
    end
  end

  def initialize(api_key: ENV.fetch('MOLLIE_API_KEY', nil))
    @api_key = api_key.to_s.strip
  end

  def configured?
    @api_key.match?(API_KEY_PATTERN)
  end

  def create_customer(name:, email:, locale:, metadata:, idempotency_key:)
    post(
      '/customers',
      {
        name: required_string(name, :name),
        email: required_string(email, :email),
        locale: required_string(locale, :locale),
        metadata: metadata
      },
      idempotency_key:
    )
  end

  def create_payment(amount_cents:, currency: 'EUR', description:, redirect_url:, cancel_url:,
                     webhook_url:, metadata:, sequence_type: 'oneoff', customer_id: nil,
                     idempotency_key:)
    sequence_type = sequence_type.to_s
    unless VALID_SEQUENCE_TYPES.include?(sequence_type)
      raise ValidationError, 'sequence_type is invalid'
    end

    if sequence_type != 'oneoff' && customer_id.nil?
      raise ValidationError, 'customer_id is required for recurring payment sequences'
    end

    body = {
      amount: amount(amount_cents, currency),
      description: required_string(description, :description),
      redirectUrl: https_url(redirect_url, :redirect_url),
      cancelUrl: optional_https_url(cancel_url, :cancel_url),
      webhookUrl: https_url(webhook_url, :webhook_url),
      metadata: metadata,
      sequenceType: sequence_type,
      customerId: optional_resource_id(customer_id, :customer)
    }.compact

    post('/payments', body, idempotency_key:)
  end

  def get_payment(payment_id)
    payment_id = resource_id(payment_id, :payment)
    response = get("/payments/#{payment_id}")
    verify_resource_response!(response, resource: 'payment', id: payment_id)
  end

  # A subscription payment id is created by Mollie, so a missed webhook leaves
  # no local id to poll. Fetch the newest full provider page for the customer;
  # the reconciliation job filters it by the exact subscription contract.
  def list_customer_payments(customer_id)
    customer_id = resource_id(customer_id, :customer)
    get(
      "/customers/#{customer_id}/payments",
      query: { limit: 250, sort: 'desc' }
    )
  end

  def list_mandates(customer_id)
    get("/customers/#{resource_id(customer_id, :customer)}/mandates")
  end

  def list_subscriptions(customer_id)
    get("/customers/#{resource_id(customer_id, :customer)}/subscriptions")
  end

  def create_subscription(customer_id:, amount_cents:, currency: 'EUR', interval: '1 month',
                          start_date:, description:, webhook_url:, metadata:, mandate_id: nil,
                          idempotency_key:)
    body = {
      amount: amount(amount_cents, currency),
      interval: subscription_interval(interval),
      startDate: optional_start_date(start_date),
      description: required_string(description, :description),
      webhookUrl: https_url(webhook_url, :webhook_url),
      metadata: metadata,
      mandateId: optional_resource_id(mandate_id, :mandate)
    }.compact

    customer_id = resource_id(customer_id, :customer)
    post("/customers/#{customer_id}/subscriptions", body, idempotency_key:)
  end

  def get_subscription(customer_id:, subscription_id:)
    customer_id = resource_id(customer_id, :customer)
    subscription_id = resource_id(subscription_id, :subscription)
    response = get("/customers/#{customer_id}/subscriptions/#{subscription_id}")
    verify_resource_response!(response, resource: 'subscription', id: subscription_id)
  end

  def update_subscription_webhook(customer_id:, subscription_id:, webhook_url:)
    customer_id = resource_id(customer_id, :customer)
    subscription_id = resource_id(subscription_id, :subscription)
    patch(
      "/customers/#{customer_id}/subscriptions/#{subscription_id}",
      webhookUrl: https_url(webhook_url, :webhook_url)
    )
  end

  def cancel_subscription(customer_id:, subscription_id:)
    customer_id = resource_id(customer_id, :customer)
    subscription_id = resource_id(subscription_id, :subscription)
    delete("/customers/#{customer_id}/subscriptions/#{subscription_id}")
  end

  # Extract a redirect destination returned by Mollie without allowing an
  # attacker-controlled URL from API data to become an open redirect.
  def checkout_url(payment)
    href = if payment.is_a?(Hash)
             payment.dig('_links', 'checkout', 'href') ||
               payment.dig(:_links, :checkout, :href)
           end

    raise ValidationError, 'Mollie checkout URL is missing' unless href.is_a?(String)

    uri = URI.parse(href)
    valid = uri.is_a?(URI::HTTPS) &&
            CHECKOUT_HOSTS.include?(uri.host) &&
            uri.port == API_PORT &&
            uri.userinfo.nil? &&
            uri.path.start_with?('/')

    raise ValidationError, 'Mollie checkout URL is not trusted' unless valid

    href
  rescue URI::InvalidURIError
    raise ValidationError, 'Mollie checkout URL is invalid'
  end

  private

  def get(path, query: nil)
    request(Net::HTTP::Get, path, query: query)
  end

  def post(path, body, idempotency_key:)
    key = validated_idempotency_key(idempotency_key)
    request(Net::HTTP::Post, path, body:, idempotency_key: key)
  end

  def patch(path, body)
    request(Net::HTTP::Patch, path, body:)
  end

  def delete(path)
    request(Net::HTTP::Delete, path)
  end

  def request(request_class, path, body: nil, idempotency_key: nil, query: nil)
    raise ConfigurationError, 'Mollie API is not configured' unless configured?

    uri = URI::HTTPS.build(host: API_HOST, path: "#{API_PREFIX}#{path}")
    uri.query = URI.encode_www_form(query) if query
    http = Net::HTTP.new(API_HOST, API_PORT)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http.write_timeout = WRITE_TIMEOUT

    request = request_class.new(uri)
    request['Accept'] = 'application/hal+json, application/json'
    request['Authorization'] = "Bearer #{@api_key}"

    if body
      request['Content-Type'] = 'application/json'
      request['Idempotency-Key'] = idempotency_key if idempotency_key
      request.body = JSON.generate(body)
    end

    parse_response(http.request(request))
  rescue Error
    raise
  rescue JSON::GeneratorError
    raise ValidationError, 'Mollie request contains invalid JSON data'
  rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError
    raise NetworkError, 'Mollie API request could not be completed'
  end

  def parse_response(response)
    status = Integer(response.code, 10)
    raise ApiError, status unless status.between?(200, 299)

    return {} if status == 204

    body = response.body.to_s
    raise InvalidResponseError, 'Mollie API returned an empty response' if body.empty?

    parsed = JSON.parse(body)
    unless parsed.is_a?(Hash)
      raise InvalidResponseError, 'Mollie API returned an unexpected JSON response'
    end

    parsed
  rescue ArgumentError, TypeError, JSON::ParserError
    raise InvalidResponseError, 'Mollie API returned invalid JSON'
  end

  def amount(amount_cents, currency)
    {
      value: format_amount(amount_cents),
      currency: normalized_currency(currency)
    }
  end

  def format_amount(amount_cents)
    unless amount_cents.is_a?(Integer) && amount_cents.positive?
      raise ValidationError, 'amount_cents must be a positive integer'
    end

    value = (BigDecimal(amount_cents.to_s) / 100).to_s('F')
    whole, fraction = value.split('.', 2)
    "#{whole}.#{fraction.to_s.ljust(2, '0')[0, 2]}"
  end

  def normalized_currency(currency)
    currency = currency.to_s.upcase
    raise ValidationError, 'currency must be a three-letter ISO code' unless currency.match?(/\A[A-Z]{3}\z/)

    currency
  end

  def required_string(value, field)
    unless value.is_a?(String) && !value.strip.empty? && !value.match?(/[\u0000-\u001F\u007F]/)
      raise ValidationError, "#{field} is invalid"
    end

    value
  end

  def https_url(value, field)
    value = required_string(value, field)
    uri = URI.parse(value)
    valid = uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil?
    raise ValidationError, "#{field} must be an HTTPS URL" unless valid

    value
  rescue URI::InvalidURIError
    raise ValidationError, "#{field} must be an HTTPS URL"
  end

  def optional_https_url(value, field)
    return nil if value.nil?

    https_url(value, field)
  end

  def resource_id(value, type)
    value = value.to_s
    pattern = RESOURCE_ID_PATTERNS.fetch(type)
    raise ValidationError, "#{type}_id is invalid" unless value.match?(pattern)

    value
  end

  def optional_resource_id(value, type)
    return nil if value.nil?

    resource_id(value, type)
  end

  def validated_idempotency_key(value)
    valid = value.is_a?(String) &&
            value.length.between?(1, MAX_IDEMPOTENCY_KEY_LENGTH) &&
            value.match?(/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/)
    raise ValidationError, 'idempotency_key is invalid' unless valid

    value
  end

  def subscription_interval(value)
    value = value.to_s
    valid = value.match?(/\A[1-9]\d* (?:day|week|month)s?\z/)
    raise ValidationError, 'interval is invalid' unless valid

    value
  end

  def optional_start_date(value)
    return nil if value.nil?

    text = value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
    valid = text.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(text).iso8601 == text
    raise ValidationError, 'start_date is invalid' unless valid

    text
  rescue Date::Error
    raise ValidationError, 'start_date is invalid'
  end

  def verify_resource_response!(response, resource:, id:)
    unless response['resource'] == resource && response['id'] == id
      raise InvalidResponseError, "Mollie returned the wrong #{resource} resource"
    end

    response
  end
end
