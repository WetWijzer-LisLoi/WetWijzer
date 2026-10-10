# frozen_string_literal: true

# == Branding Helper
#
# Site-level branding for web pages: which of the four products the reader
# is looking at, and the name, address and links that belong to it.
#
# THE BRAND IS THE DOMAIN, NOT THE LANGUAGE. A request on lisloi.be is LisLoi
# whatever language the page is served in, so every method here resolves the
# brand from the request host through SiteBrand first. The locale is only the
# fallback for hosts that carry no brand (localhost, a bare IP, the test
# default host), where it is the best remaining signal.
#
# Keyed on the locale alone, as these methods were until 2026-10-04, a
# WetWijzer page served in French called itself LisLoi. Mail has its own
# resolution in MailerBrandingHelper, which must stay out of app/helpers.
module BrandingHelper
  LOCALE_BRANDS = SiteBrand::LOCALES.invert.freeze

  CONTACT_EMAILS = {
    'wetwijzer' => 'info@wetwijzer.be',
    'lisloi' => 'info@lisloi.be',
    'gesetzguide' => 'info@gesetzguide.be',
    # LexLibera's inbox lives on the Praxis domain, deliberately.
    'lexlibera' => 'info@praxislegal.be'
  }.freeze

  OG_IMAGES = {
    'wetwijzer' => 'https://wetwijzer.be/images/og-wetwijzer.png',
    'lisloi' => 'https://lisloi.be/images/og-lisloi.png',
    'gesetzguide' => 'https://gesetzguide.be/images/og-gesetzguide.png',
    'lexlibera' => 'https://lexlibera.be/images/og-lexlibera.png'
  }.freeze

  UMAMI_ENV_KEYS = {
    'wetwijzer' => 'UMAMI_WEBSITE_ID_NL',
    'lisloi' => 'UMAMI_WEBSITE_ID_FR',
    'gesetzguide' => 'UMAMI_WEBSITE_ID_DE',
    'lexlibera' => 'UMAMI_WEBSITE_ID_EN'
  }.freeze

  # The canonical brand code for this request: the host's brand when the host
  # is one of ours, else the brand whose language the page is served in.
  # @return [String] one of SiteBrand::KEYS
  def site_brand
    request_brand || LOCALE_BRANDS.fetch(I18n.locale.to_s, 'wetwijzer')
  end

  # @return [String] Site name (WetWijzer, LisLoi, GesetzGuide or LexLibera)
  def site_name
    SiteBrand::LABELS.fetch(site_brand)
  end

  # @return [String] Contact email for the brand the reader is on
  def contact_email
    CONTACT_EMAILS.fetch(site_brand)
  end

  # @return [String] Site URL
  def site_url
    "https://#{SiteBrand::CANONICAL_DOMAINS.fetch(site_brand)}"
  end

  # Global site navigation always opens the other brand's homepage. Page
  # translation controls are separate: no current path, search, account token
  # or other request parameter belongs in these links. Keep local checks local.
  def language_switch_url(locale)
    locale = locale.to_s
    brand = LOCALE_BRANDS.fetch(locale)
    origin = if request.host.end_with?('.localhost')
               "#{request.protocol}#{brand}.localhost#{request.port_string}"
             elsif SiteBrand.resolve_request(request)
               "https://#{SiteBrand.canonical_domain_for(brand)}"
             else
               # A bare local preview has no brand host to select its language.
               return "#{request.protocol}#{request.host}#{request.port_string}/?locale=#{locale}"
             end
    "#{origin}/"
  end

  # @return [String] OpenGraph image URL
  def site_og_image
    OG_IMAGES.fetch(site_brand)
  end

  # Language, not brand: a French page is fr_BE whichever domain serves it.
  # @return [String] Locale string like 'nl_BE', 'fr_BE', 'de_BE'
  def site_og_locale
    case I18n.locale
    when :fr then 'fr_BE'
    when :de then 'de_BE'
    when :en then 'en'
    else 'nl_BE'
    end
  end

  # Returns the Umami analytics website ID for the current brand.
  # Each domain has a separate tracking ID in the shared Umami instance.
  # @return [String, nil] Umami website ID or nil if not configured
  def umami_website_id
    ENV[UMAMI_ENV_KEYS.fetch(site_brand)] || ENV.fetch('UMAMI_WEBSITE_ID', nil)
  end

  # All brands use the same Umami instance at analytics.wetwijzer.be.
  # Traffic is separated by the per-brand website_id, not by hostname.
  # @return [String] The analytics hostname
  def umami_analytics_host
    'analytics.wetwijzer.be'
  end

  private

  # The host's brand, or nil when there is no request (mail views, some
  # helper tests) or the host is not a product host.
  def request_brand
    return nil unless respond_to?(:request, true)

    current_request = request
    return nil unless current_request.respond_to?(:host)

    SiteBrand.resolve_request(current_request)
  end
end
