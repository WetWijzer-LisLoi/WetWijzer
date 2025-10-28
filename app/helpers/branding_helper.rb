# frozen_string_literal: true

# == Branding Helper
#
# Site-level branding methods that depend on the current locale/request domain.
# Extracted from ApplicationHelper for clarity.
module BrandingHelper
  # Returns the appropriate contact email based on the current domain
  # @return [String] Contact email (info@wetwijzer.be, info@lisloi.be, info@gesetzguide.be, or info@praxislegal.be)
  def contact_email
    host = request.host.to_s.downcase
    if host.include?('lisloi')
      'info@lisloi.be'
    elsif host.include?('gesetzguide')
      'info@gesetzguide.be'
    elsif host.include?('lexlibera')
      'info@praxislegal.be'
    else
      'info@wetwijzer.be'
    end
  end

  # Returns the site name based on the current locale
  # @return [String] Site name (WetWijzer, LisLoi, or GesetzGuide)
  def site_name
    case I18n.locale
    when :fr then 'LisLoi'
    when :de then 'GesetzGuide'
    when :en then 'LexLibera'
    else 'WetWijzer'
    end
  end

  # Returns the site URL based on the current locale
  # @return [String] Site URL
  def site_url
    case I18n.locale
    when :fr then 'https://lisloi.be'
    when :de then 'https://gesetzguide.be'
    when :en then 'https://lexlibera.be'
    else 'https://wetwijzer.be'
    end
  end

  # Returns the OpenGraph image URL based on the current locale
  # @return [String] OG image URL
  def site_og_image
    case I18n.locale
    when :fr then 'https://lisloi.be/images/og-lisloi.png'
    when :de then 'https://gesetzguide.be/images/og-gesetzguide.png'
    when :en then 'https://lexlibera.be/images/og-lexlibera.png'
    else 'https://wetwijzer.be/images/og-wetwijzer.png'
    end
  end

  # Returns the site locale string for OpenGraph
  # @return [String] Locale string like 'nl_BE', 'fr_BE', 'de_BE'
  def site_og_locale
    case I18n.locale
    when :fr then 'fr_BE'
    when :de then 'de_BE'
    when :en then 'en'
    else 'nl_BE'
    end
  end

  # Returns the Umami analytics website ID for the current brand
  # Each domain has a separate tracking ID in the shared Umami instance
  # @return [String, nil] Umami website ID or nil if not configured
  def umami_website_id
    case I18n.locale
    when :fr then ENV['UMAMI_WEBSITE_ID_FR'] || ENV.fetch('UMAMI_WEBSITE_ID', nil)
    when :de then ENV['UMAMI_WEBSITE_ID_DE'] || ENV.fetch('UMAMI_WEBSITE_ID', nil)
    when :en then ENV['UMAMI_WEBSITE_ID_EN'] || ENV.fetch('UMAMI_WEBSITE_ID', nil)
    else ENV['UMAMI_WEBSITE_ID_NL'] || ENV.fetch('UMAMI_WEBSITE_ID', nil)
    end
  end

  # Returns the brand-specific Umami analytics hostname
  # Each brand loads the tracking script from its own subdomain to avoid
  # cross-domain warnings in privacy/security browser extensions
  # @return [String] The analytics hostname (e.g. analytics.wetwijzer.be)
  def umami_analytics_host
    case I18n.locale
    when :fr then 'analytics.lisloi.be'
    when :de then 'analytics.gesetzguide.be'
    when :en then 'analytics.lexlibera.be'
    else 'analytics.wetwijzer.be'
    end
  end

  # Returns the alternate language ID (1 for NL, 2 for FR)
  # @param current_language_id [Integer] The current language ID
  # @return [Integer] The alternate language ID
  def alternate_language_id(current_language_id)
    current_language_id == 1 ? 2 : 1
  end

  # Returns the translation key for switching to the other language
  # @param current_language_id [Integer] The current language ID
  # @return [String] Translation key for the language switch link
  def switch_language_key(current_language_id)
    current_language_id == 1 ? :switch_to_french : :switch_to_dutch
  end
end
