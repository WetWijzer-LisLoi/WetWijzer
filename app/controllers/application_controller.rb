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
  # DISABLED - blocks legitimate older browsers; bot abuse is handled by
  # GeoChallenge + Rack::Attack instead. (No CDN/proxy in front of nginx.)
  # allow_browser versions: :modern

  include Pagy::Method # Pagy v43 unified methods
  include HostDetection
  include GeoChallenge
  include CookieFlash
  include ClassicRouting

  # Dynamic layout: classic.* subdomain gets the no-JS minimal layout
  layout :choose_layout

  # Any page classic does not serve (ClassicRouting) is a modern-only view on
  # a classic.* host: its Tailwind/Stimulus body renders as unstyled soup
  # inside the classic layout, so hand those requests to the modern site.
  before_action :redirect_unported_classic_pages, if: :classic_host?

  # Global exception handlers - show proper error pages instead of crashing
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActionController::RoutingError, with: :not_found
  rescue_from AbstractController::ActionNotFound, with: :not_found

  rescue_from ActionController::InvalidAuthenticityToken do |_e|
    respond_to do |format|
      format.html do
        redirect_to root_path,
                    alert: t('errors.session_expired', default: 'Your session has expired. Please try again.')
      end
      format.json { render json: { error: 'invalid_csrf_token' }, status: :unprocessable_entity }
      format.any { head :unprocessable_entity }
    end
  end

  rescue_from BCrypt::Errors::InvalidHash do |e|
    Rails.logger.error("BCrypt InvalidHash: #{e.message}")
    server_error(e)
  end

  # Set the locale around each request
  around_action :switch_locale
  around_action :with_account_request_lease

  # CSRF protection enabled for security
  # Note: If your application truly has no forms/mutations, you can disable this
  # but ensure GET requests never mutate state
  protect_from_forgery with: :exception

  # Make the http_accept_language method available to views
  helper_method :http_accept_language
  helper_method :current_language_id
  helper_method :content_lang
  helper_method :german_site?
  helper_method :current_user
  helper_method :logged_in?
  helper_method :staging_host?
  helper_method :classic_host?

  # Keep an explicitly selected Classic appearance on ordinary server-rendered
  # links. It is a URL preference, not a cookie: Classic pages are publicly
  # cacheable and must not leak one reader's appearance to another.
  def default_url_options
    return {} unless classic_host?

    theme = params[:classic_theme].to_s
    ClassicHelper::CLASSIC_THEMES.include?(theme) && theme != 'system' ? { classic_theme: theme } : {}
  end

  # Switches the locale for the current request
  # @yield The action to be performed with the switched locale
  # @return [void]
  # @raise [I18n::InvalidLocale] if the requested locale is not available
  # @note Uses the locale extracted from the domain name or falls back to default
  def switch_locale(&)
    locale = extract_locale_from_domainname.presence || I18n.default_locale
    I18n.with_locale(locale) do
      redirect_if_wrong_domain! and return
      yield
    end
  rescue I18n::InvalidLocale => e
    # Log the error and fall back to default locale
    Rails.logger.error("Invalid locale requested: #{e.message}")
    I18n.with_locale(I18n.default_locale, &)
  end

  private

  # Select layout based on subdomain
  def choose_layout
    classic_host? ? 'classic' : 'application'
  end

  # See ClassicRouting. One redirect to the same path and query on the modern
  # host, which never sends it back. 302 (not 301) so pages ported to classic
  # later aren't stuck behind cached permanent redirects; 303 for non-GET so
  # a stray form submit lands on the modern page instead of re-POSTing.
  def redirect_unported_classic_pages
    return if classic_serves_request?

    modern_url = classic_peer_url(effective_host.to_s.delete_prefix('classic.'), request.fullpath)
    redirect_to modern_url, allow_other_host: true, status: request.get? || request.head? ? :found : :see_other
  end

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
    return 'de' if labels.include?('gesetzguide') && german_available?
    return 'en' if labels.include?('lexlibera') && english_available?

    nil
  end

  # Redirect to the correct brand domain when ?locale= doesn't match current host
  # E.g., wetwijzer.be?locale=en → lexlibera.be
  # Only triggers on explicit locale param to avoid redirect loops
  LOCALE_DOMAINS = {
    'nl' => 'wetwijzer.be',
    'fr' => 'lisloi.be',
    'de' => 'gesetzguide.be',
    'en' => 'lexlibera.be'
  }.freeze

  def redirect_if_wrong_domain!
    return false unless params[:locale].present? # only on explicit locale switch
    return false unless request.get? # don't redirect POSTs/PATCHs
    return false if staging_host?                   # skip on staging subdomains
    return false if classic_host?                   # skip on classic subdomains
    return false if request.format.json? || request.xhr?

    # Local preview language links use ?locale= on loopback hosts. Never send
    # those browser checks to a live product just to change interface language.
    host = effective_host.to_s.downcase
    return false if %w[localhost 127.0.0.1 ::1].include?(host) || host.end_with?('.localhost')

    correct_domain = LOCALE_DOMAINS[I18n.locale.to_s]
    return false unless correct_domain

    return false if host.include?(correct_domain.split('.').first)

    # Build redirect URL: same path, same query params minus locale
    new_params = request.query_parameters.except('locale')
    query = new_params.any? ? "?#{new_params.to_query}" : ''
    redirect_to "https://#{correct_domain}#{request.path}#{query}", allow_other_host: true, status: :moved_permanently
    true
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

  # Checks if German locale is available in the application
  # @return [Boolean] true if German locale is available, false otherwise
  # @see I18n.available_locales
  def german_available?
    @german_available ||= I18n.available_locales.include?(:de)
  end

  # Checks if English locale is available in the application
  # @return [Boolean] true if English locale is available, false otherwise
  # @see I18n.available_locales
  def english_available?
    @english_available ||= I18n.available_locales.include?(:en)
  end

  # Maps a locale to the corresponding numeric language_id used in the database.
  # The German site shows a law in German when the NUMAC has a German text it
  # serves (phase B of docs/ops/german-corpus-plan-2026-09-27.md) and in French
  # otherwise, so its answer depends on the law: without a numac it is the
  # French fallback, as before.
  # @param locale [String, Symbol] the locale code (defaults to I18n.locale)
  # @param numac [String, nil] the law the language is chosen for
  # @return [Integer] 1 for Dutch, 2 for French, 3 for a German text on the
  #   German site. Defaults to 1.
  def current_language_id(locale = I18n.locale, numac: nil)
    case locale.to_s
    when 'fr' then 2
    when 'de' then german_text_for?(numac) ? HasLanguage::GERMAN_LANGUAGE_ID : 2
    when 'en'
      # LexLibera: read from param first, then cookie fallback
      cl = params[:content_lang].presence || cookies[:content_lang]
      cl == 'fr' ? 2 : 1
    else 1 # default to Dutch
    end
  end

  # Returns the content language code for the current request.
  # For LexLibera (EN locale), this is determined by the content_lang param or cookie.
  # For other locales, it matches the UI locale.
  # @return [String] 'nl', 'fr' or 'de'
  def content_lang
    case I18n.locale
    when :en
      cl = params[:content_lang].presence || cookies[:content_lang]
      cl == 'fr' ? 'fr' : 'nl'
    when :fr then 'fr'
    when :de then 'de'
    else 'nl'
    end
  end

  # The German site (gesetzguide.be and its classic and staging hosts). Since
  # phase B of the German plan it serves the German texts (language_id 3)
  # beside the French and Dutch ones; the Dutch and French sites never do.
  def german_site?
    I18n.locale == :de
  end

  # The legislation rows this site serves: languages 1 and 2 everywhere, and
  # on the German site also the German rows with a known provenance.
  def served_legislation
    german_site? ? Legislation.served_on_german_site : Legislation.in_site_languages
  end

  # Whether the German site has a German text for this NUMAC.
  def german_text_for?(numac)
    numac.present? && Legislation.german_with_provenance.exists?(numac: numac.to_s)
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
    @current_user = token.present? ? User.find_by(session_token: token, active: true) : nil
    clear_stale_account_cookie! if token.present? && @current_user.nil?
    @current_user
  end

  # Every request authenticated by the normal user cookie owns a durable lease
  # for its full controller lifetime. Machine endpoints and the separate admin
  # cookie do not authenticate with this cookie and must not accidentally lease
  # an unrelated user that happens to be signed in in the same browser.
  def with_account_request_lease
    lease = nil
    token = cookies.signed[:session_token]

    if token.present? && account_request_lease_applicable?
      begin
        lease = AccountRequestLease.acquire_for_session!(session_token: token)
        if lease
          @account_request_lease = lease
          @current_user = lease.user
        else
          @current_user = nil
          clear_stale_account_cookie!
        end
      rescue ActiveRecord::ActiveRecordError => e
        # Authentication must fail closed if the accounts database or lease
        # table is unavailable. Preserve the signed cookie: infrastructure
        # failure is not evidence that the user's durable session was revoked.
        # Anonymous/public requests can still render for this one request.
        Rails.logger.error("Account request lease acquisition failed: #{e.class}")
        @current_user = nil
      end
    end

    yield
  ensure
    begin
      lease&.release!
    rescue ActiveRecord::ActiveRecordError => e
      # Leaving the durable row behind is safe: erasure will not pass it until
      # the request hard ceiling makes it provably stale.
      Rails.logger.error("Account request lease release deferred: #{e.class}")
    ensure
      @account_request_lease = nil
    end
  end

  def account_request_lease_applicable?
    !controller_path.start_with?('admin/', 'webhooks/', 'api/partner')
  end

  def clear_stale_account_cookie!
    cookies.delete(:session_token)
  end

  def logged_in?
    current_user.present?
  end

  # WW-PRIV-03: no return_to cookie. It kept the full path, query string
  # included, in a merely signed cookie, and nothing ever read it back.
  def require_authentication
    return if logged_in?

    redirect_to login_path, alert: t('auth.login_required')
  end
end
