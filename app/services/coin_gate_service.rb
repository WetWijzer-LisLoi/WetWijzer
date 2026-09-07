# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'timeout'
require 'uri'

# CoinGate API v2 integration for cryptocurrency payments.
# Creates an order, redirects to hosted checkout, then verifies the callback.
#
# Environment variables required:
#   COINGATE_API_TOKEN     - API auth token from CoinGate dashboard
#   COINGATE_WEBHOOK_TOKEN - Shared secret for webhook verification
#   COINGATE_ENVIRONMENT   - "sandbox" or "live" (default: sandbox)
#
# @see https://developer.coingate.com/reference/cryptocurrency-payment-api
class CoinGateService
  BASE_URLS = {
    'live' => 'https://api.coingate.com/api/v2',
    'sandbox' => 'https://api-sandbox.coingate.com/api/v2'
  }.freeze
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 30
  WRITE_TIMEOUT = 10
  ORDER_ID = /\A[1-9]\d*\z/
  MERCHANT_ORDER_ID = /\A(?:sub|credit)_\d+_\d+\z/

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error; end

  def initialize
    @token = ENV.fetch('COINGATE_API_TOKEN', '').strip
    @environment = ENV.fetch('COINGATE_ENVIRONMENT', 'sandbox')
    @base_url = BASE_URLS[@environment]
  end

  def configured?
    @token.present? &&
      @base_url.present? &&
      (!Rails.env.production? || @environment == 'live')
  end

  # Create a CoinGate hosted-checkout order.
  #
  # @param price_amount [Numeric] Amount in EUR (e.g. 2.99)
  # @param title [String] Short description shown on invoice
  # @param description [String] Longer description
  # @param order_id [String] Your internal reference (e.g. "sub_42" or "credit_123")
  # @param callback_url [String] Webhook URL for status updates
  # @param success_url [String] Redirect after payment
  # @param cancel_url [String] Redirect on cancel
  # @param token [String] Unique token for webhook verification
  # @return [Hash] CoinGate order including :payment_url
  def create_order(price_amount:, title:, description: nil, order_id: nil,
                   callback_url: nil, success_url: nil, cancel_url: nil, token: nil)
    raise ConfigurationError, 'CoinGate API token not configured' unless configured?

    body = {
      price_amount: price_amount,
      price_currency: 'EUR',
      receive_currency: 'EUR', # Auto-convert to EUR (zero volatility)
      title: title.truncate(150),
      description: description&.truncate(500),
      order_id: order_id,
      callback_url: callback_url,
      success_url: success_url,
      cancel_url: cancel_url,
      token: token
    }.compact

    response = post('/orders', body)
    validate_created_order!(response, order_id)
  end

  # Retrieve an existing order (for double-checking webhook data).
  #
  # @param coingate_order_id [Integer] CoinGate's internal order ID
  # @return [Hash] Order details including status
  def get_order(coingate_order_id)
    raise ConfigurationError, 'CoinGate API token not configured' unless configured?

    order_id = coingate_order_id.to_s
    raise ApiError, 'CoinGate order id is invalid' unless order_id.match?(ORDER_ID)

    get("/orders/#{order_id}")
  end

  # Verify webhook token matches what we sent when creating the order.
  #
  # @param received_token [String] Token from webhook payload
  # @param expected_token [String] Token we stored when creating the order
  # @return [Boolean]
  def self.verify_token(received_token, expected_token)
    return false if received_token.blank? || expected_token.blank?

    ActiveSupport::SecurityUtils.secure_compare(received_token, expected_token)
  end

  private

  def validate_created_order!(order, merchant_order_id)
    unless merchant_order_id.to_s.match?(MERCHANT_ORDER_ID) &&
           order[:id].to_s.match?(ORDER_ID) &&
           order[:order_id].to_s == merchant_order_id.to_s
      raise ApiError, 'CoinGate returned a mismatched order'
    end

    payment_url = order[:payment_url].to_s
    uri = URI.parse(payment_url)
    host = uri.host.to_s.downcase
    trusted_host = host == 'coingate.com' || host.end_with?('.coingate.com')
    unless uri.is_a?(URI::HTTPS) &&
           trusted_host &&
           uri.port == 443 &&
           uri.userinfo.nil?
      raise ApiError, 'CoinGate returned an untrusted checkout URL'
    end

    order
  rescue URI::InvalidURIError
    raise ApiError, 'CoinGate returned an invalid checkout URL'
  end

  def post(path, body)
    uri = URI("#{@base_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Token #{@token}"
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request.body = body.to_json

    perform_request(uri, request)
  end

  def get(path)
    uri = URI("#{@base_url}#{path}")

    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Token #{@token}"
    request['Accept'] = 'application/json'

    perform_request(uri, request)
  end

  def perform_request(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http.write_timeout = WRITE_TIMEOUT

    handle_response(http.request(request))
  rescue Timeout::Error, SocketError, SystemCallError,
         OpenSSL::SSL::SSLError, IOError
    raise ApiError, 'CoinGate API request could not be completed'
  end

  def handle_response(response)
    case response.code.to_i
    when 200..299
      parsed = JSON.parse(response.body, symbolize_names: true)
      raise ApiError, 'CoinGate returned an unexpected response' unless parsed.is_a?(Hash)

      parsed
    when 401
      raise ApiError, 'CoinGate authentication failed - check COINGATE_API_TOKEN'
    when 422
      raise ApiError, 'CoinGate rejected the request'
    when 429
      raise ApiError, 'CoinGate rate limit exceeded'
    else
      raise ApiError, "CoinGate API error (HTTP #{response.code})"
    end
  rescue JSON::ParserError
    raise ApiError, 'CoinGate returned invalid JSON'
  end
end
