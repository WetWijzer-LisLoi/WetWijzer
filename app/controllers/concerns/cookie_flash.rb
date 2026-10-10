# frozen_string_literal: true

# Cookie-based flash messages for the public site.
#
# Rails flash middleware is disabled globally. This concern provides the same
# flash semantics using signed cookies instead, while the otherwise minimal
# Rails session remains available only for CSRF protection.
#
# On redirect: notice:/alert: options are packed into a single-use
# signed cookie (_flash). On next GET: the cookie is consumed and
# exposed via flash[:notice] / flash[:alert] / flash.now[:alert].
#
# Mirrors the pattern used in Admin::BaseController._admin_flash.
module CookieFlash
  extend ActiveSupport::Concern

  CLASSIC_FLASH_DOMAINS = %w[wetwijzer.be lisloi.be gesetzguide.be lexlibera.be
                             wetwijzer.localhost lisloi.localhost gesetzguide.localhost lexlibera.localhost].freeze
  CLASSIC_FLASH_LIFETIME = 30
  CLASSIC_FLASH_MESSAGE_BYTES = 512
  CLASSIC_FLASH_PATH_BYTES = 1024
  CLASSIC_FLASH_PAYLOAD_BYTES = 2000

  included do
    before_action :load_cookie_flash
    after_action :finish_classic_flash_response
    helper_method :flash, :classic_flash_received?
  end

  private

  # Load and consume the cookie flash on every request
  def load_cookie_flash
    raw = cookies.signed[:_flash]
    cookies.delete(:_flash) # consume immediately - single use
    @cookie_flash = raw.present? ? JSON.parse(raw) : {}
  rescue JSON::ParserError
    @cookie_flash = {}
  end

  # Override Rails flash to return cookie-based flash
  # Supports both flash[:notice] and flash[:alert]
  def flash
    load_classic_cookie_flash
    @flash ||= CookieFlashProxy.new(@cookie_flash || {})
  end

  # The modern layout calls this only when it offers the same full page on
  # Classic. Authentication and the normal _flash cookie stay host-only;
  # this separate encrypted cookie carries only a short-lived notice/alert.
  def forward_flash_to_classic!(classic_url)
    return false if @classic_flash_forwarded || !classic_flash_full_page?

    domain = request.host if CLASSIC_FLASH_DOMAINS.include?(request.host)
    return false unless domain

    destination = URI.parse(classic_url)
    return false unless destination.host == "classic.#{domain}" && destination.scheme == request.scheme &&
                        destination.port == request.port && destination.request_uri == request.fullpath
    return false if request.fullpath.bytesize > CLASSIC_FLASH_PATH_BYTES

    messages = bounded_classic_flash_messages(flash.to_hash)
    return false if messages.empty?

    payload = { 'host' => destination.host, 'path' => destination.request_uri,
                'expires_at' => Time.current.to_i + CLASSIC_FLASH_LIFETIME, 'messages' => messages }
    return false if payload.to_json.bytesize > CLASSIC_FLASH_PAYLOAD_BYTES

    cookies.encrypted[:_classic_flash] = {
      value: payload, domain: domain, path: '/', httponly: true,
      secure: Rails.env.production?, same_site: :lax, expires: CLASSIC_FLASH_LIFETIME.seconds.from_now
    }
    @classic_flash_forwarded = true
    make_classic_flash_response_private
    true
  rescue URI::InvalidURIError
    false
  end

  def classic_flash_received?
    load_classic_cookie_flash
    @classic_flash_received == true
  end

  def classic_flash_private_response?
    @classic_flash_forwarded || @classic_flash_received
  end

  # Decrypt only while rendering the intended successful Classic HTML page.
  # In particular, a frame or a canonical redirect must leave it available
  # for the eventual full-page request.
  def load_classic_cookie_flash
    return if @classic_flash_checked
    return unless classic_flash_full_page?

    domain = request.host.delete_prefix('classic.')
    return unless request.host == "classic.#{domain}" && CLASSIC_FLASH_DOMAINS.include?(domain)

    @classic_flash_checked = true
    payload = cookies.encrypted[:_classic_flash]
    return unless payload.is_a?(Hash) && payload.to_json.bytesize <= CLASSIC_FLASH_PAYLOAD_BYTES
    return unless payload['host'] == request.host && payload['path'] == request.fullpath

    expiry = payload['expires_at']
    now = Time.current.to_i
    return unless expiry.is_a?(Integer) && expiry > now && expiry <= now + CLASSIC_FLASH_LIFETIME

    messages = bounded_classic_flash_messages(payload['messages'])
    return if messages.empty? || messages != payload['messages']

    @cookie_flash = messages.merge(@cookie_flash || {})
    @classic_flash_received = true
    @classic_flash_domain = domain
    make_classic_flash_response_private
  end

  def classic_flash_full_page?
    request.get? && request.format.html? && !turbo_frame_request? && !request.xhr? &&
      response.status == 200 && classic_page?
  end

  def bounded_classic_flash_messages(messages)
    return {} unless messages.is_a?(Hash)

    messages.slice('notice', 'alert').select do |_, value|
      value.is_a?(String) && value.valid_encoding? && value.present? && value.bytesize <= CLASSIC_FLASH_MESSAGE_BYTES
    end
  end

  def make_classic_flash_response_private
    response.cache_control.clear
    response.cache_control[:private] = true
    response.cache_control[:no_store] = true
    response.headers['Cache-Control'] = 'private, no-store'
  end

  # Registered on ApplicationController, so this runs after a child's cache
  # callbacks too. Only the final successful page consumes the bridge.
  def finish_classic_flash_response
    if classic_flash_full_page? && classic_host?
      # A fresh anonymous Classic response must not hide a newly issued
      # handoff cookie by being reused before this request reaches Rails.
      vary = response.headers['Vary'].to_s.split(',').map(&:strip)
      response.headers['Vary'] = (vary + ['Cookie']).join(', ') unless vary.any? { |header| header.casecmp?('Cookie') }
    end

    return unless classic_flash_private_response?

    make_classic_flash_response_private
    return unless @classic_flash_received && response.status == 200

    cookies.delete(:_classic_flash, domain: @classic_flash_domain, path: '/')
  end

  # Override redirect_to to intercept notice: and alert: options
  # and store them in a signed cookie instead of Rails session
  def redirect_to(options = {}, response_options = {})
    notice = response_options.delete(:notice)
    alert = response_options.delete(:alert)
    flash_hash = response_options.delete(:flash) || {}

    flash_hash['notice'] = notice if notice.present?
    flash_hash['alert'] = alert if alert.present?

    if flash_hash.any?
      cookies.signed[:_flash] = {
        value: flash_hash.to_json,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax,
        expires: 30.seconds.from_now
      }
    end

    super
  end

  # Minimal flash proxy that behaves like ActionDispatch::Flash::FlashHash
  # for view compatibility (flash[:notice], flash[:alert], etc.)
  class CookieFlashProxy
    def initialize(hash = {})
      @hash = hash.stringify_keys
    end

    def [](key)
      @hash[key.to_s]
    end

    def []=(key, value)
      @hash[key.to_s] = value
    end

    def now
      self # flash.now[:alert] = ... just stores in-memory (same request)
    end

    def any?
      @hash.any?
    end

    def empty?
      @hash.empty?
    end

    def each(&)
      @hash.each(&)
    end

    def to_hash
      @hash
    end

    def key?(key)
      @hash.key?(key.to_s)
    end
  end
end
