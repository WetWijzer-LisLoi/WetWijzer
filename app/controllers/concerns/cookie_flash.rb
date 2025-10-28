# frozen_string_literal: true

# Cookie-based flash messages for the public site.
#
# Rails flash middleware is disabled globally (config.session_store :disabled)
# for GDPR privacy. This concern provides the same flash semantics using
# signed cookies instead.
#
# On redirect: notice:/alert: options are packed into a single-use
# signed cookie (_flash). On next GET: the cookie is consumed and
# exposed via flash[:notice] / flash[:alert] / flash.now[:alert].
#
# Mirrors the pattern used in Admin::BaseController._admin_flash.
module CookieFlash
  extend ActiveSupport::Concern

  included do
    before_action :load_cookie_flash
    helper_method :flash
  end

  private

  # Load and consume the cookie flash on every request
  def load_cookie_flash
    raw = cookies.signed[:_flash]
    cookies.delete(:_flash) # consume immediately — single use
    @cookie_flash = raw.present? ? JSON.parse(raw) : {}
  rescue JSON::ParserError
    @cookie_flash = {}
  end

  # Override Rails flash to return cookie-based flash
  # Supports both flash[:notice] and flash[:alert]
  def flash
    @cookie_flash_proxy ||= CookieFlashProxy.new(@cookie_flash || {})
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

    super(options, response_options)
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
