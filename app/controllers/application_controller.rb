# frozen_string_literal: true

# == Application Controller
#
# Base controller for the WetWijzer application that provides common functionality
# to all controllers. Handles internationalization, session management, and
# provides helper methods for views.
#
# @example Basic usage
#   # In a controller:
#   class MyController < ApplicationController
#     def index
#       # Your code here
#     end
#   end
#
# @see https://guides.rubyonrails.org/action_controller_overview.html
class ApplicationController < ActionController::Base
  # CSRF / Security setup
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # DISABLED: Conflicts with Cloudflare proxy - use Cloudflare's bot protection instead
  # allow_browser versions: :modern

  include Pagy::Method # Pagy v43 unified methods
  include HostDetection

  # Set the locale around each request
  around_action :switch_locale

  # CSRF protection enabled for security
  # Note: If your application truly has no forms/mutations, you can disable this
  # but ensure GET requests never mutate state
  protect_from_forgery with: :exception

  # Make the http_accept_language method available to views
  helper_method :http_accept_language
  helper_method :current_language_id
  helper_method :current_user
  helper_method :logged_in?

  # Default URL options for URL generation
  # @return [Hash] Default URL options including dark mode preference
  # @example
  #   # In a view:
  #   root_path # => "/?dark_mode=dark" (if dark mode is enabled)
  def default_url_options
    params[:dark_mode] == 'dark' ? { dark_mode: 'dark' } : {}
  end

  # Switches the locale for the current request
  # @yield The action to be performed with the switched locale
  # @return [void]
  # @raise [I18n::InvalidLocale] if the requested locale is not available
  # @note Uses the locale extracted from the domain name or falls back to default
  def switch_locale(&)
    locale = extract_locale_from_domainname.presence || I18n.default_locale
    I18n.with_locale(locale, &)
  rescue I18n::InvalidLocale => e
    # Log the error and fall back to default locale
    Rails.logger.error("Invalid locale requested: #{e.message}")
    I18n.with_locale(I18n.default_locale, &)
  end

  private

  # Extracts the locale from the domain name based on subdomain
  # @return [String, nil] The locale code ('nl' or 'fr') or nil if not found
  # @example
  #   # For request to 'wetwijzer.example.com':
  #   extract_locale_from_domainname # => "nl"
  #
  #   # For request to 'lisloi.example.com':
  #   extract_locale_from_domainname # => "fr"
  def extract_locale_from_domainname
    locale_from_params || locale_from_host(effective_host) || locale_from_browser
  end

  def locale_from_browser
    http_accept_language.compatible_language_from(I18n.available_locales) || I18n.default_locale
  end

  # Extract valid locale from params
  def locale_from_params
    l = params[:locale].presence
    return unless l

    I18n.available_locales.include?(l.to_sym) ? l : nil
  end

  # Determine locale from host labels (e.g., staging.lisloi.be)
  def locale_from_host(host)
    labels = host.to_s.downcase.split('.')
    return 'nl' if labels.include?('wetwijzer') && dutch_available?
    return 'fr' if labels.include?('lisloi') && french_available?

    nil
  end

  # Checks if Dutch locale is available in the application
  # @return [Boolean] true if Dutch locale is available, false otherwise
  # @see I18n.available_locales
  def dutch_available?
    @dutch_available ||= I18n.available_locales.include?(:nl)
  end

  # Checks if French locale is available in the application
  # @return [Boolean] true if French locale is available, false otherwise
  # @see I18n.available_locales
  # @note This method is memoized to avoid repeated checks against I18n.available_locales
  def french_available?
    @french_available ||= I18n.available_locales.include?(:fr)
  end

  # Maps a locale to the corresponding numeric language_id used in the database.
  # @param locale [String, Symbol] the locale code (defaults to I18n.locale)
  # @return [Integer] 1 for Dutch (nl), 2 for French (fr). Defaults to 1.
  def current_language_id(locale = I18n.locale)
    case locale.to_s
    when 'fr' then 2
    else 1 # default to Dutch
    end
  end

  # Handles routing errors with a custom 404 page
  # @return [void]
  # @note This method is called by the router when no route matches
  def not_found
    respond_to do |format|
      format.html { render 'errors/not_found', status: :not_found }
      format.json { render json: { error: 'Not Found' }, status: :not_found }
      format.any { head :not_found }
    end
  end

  # Handles server errors with a custom 500 page
  # @param exception [Exception] The exception that was raised
  # @return [void]
  # @note This method is called by the exception handler
  def server_error(exception = nil)
    # Log the error for debugging
    Rails.logger.error("Server Error: #{exception.message}\n#{exception.backtrace.join("\n")}") if exception

    respond_to do |format|
      format.html { render 'errors/internal_server_error', status: :internal_server_error }
      format.json { render json: { error: 'Internal Server Error' }, status: :internal_server_error }
    end
  end

  # Authentication helpers
  def current_user
    return @current_user if defined?(@current_user)

    token = cookies.signed[:session_token]
    @current_user = token.present? ? User.find_by(session_token: token) : nil
  end

  def logged_in?
    current_user.present?
  end

  def require_authentication
    unless logged_in?
      store_location
      redirect_to login_path, alert: t('auth.login_required')
    end
  end

  def store_location
    # Use signed cookie instead of session (sessions are disabled for privacy)
    cookies.signed[:return_to] = { value: request.fullpath, expires: 5.minutes.from_now, httponly: true } if request.get?
  end

  def stored_location_or(default)
    location = cookies.signed[:return_to]
    cookies.delete(:return_to)
    location || default
  end
end
