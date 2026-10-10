# frozen_string_literal: true

# Which address a transactional mail is sent AS, and with which SMTP account.
#
# WHY THE TWO MOVE TOGETHER
# -------------------------
# Migadu authenticates one mailbox and refuses any envelope sender that is not
# that mailbox. Probed against smtp.migadu.com on 2026-09-08, authenticated as
# noreply@wetwijzer.be:
#
#   MAIL FROM:<noreply@wetwijzer.be>   -> 250 accepting mail
#   MAIL FROM:<noreply@lisloi.be>      -> 550 5.7.1 sender address rejected
#   MAIL FROM:<noreply@gesetzguide.be> -> 550 5.7.1 sender address rejected
#   MAIL FROM:<noreply@lexlibera.be>   -> 550 5.7.1 sender address rejected
#
# and that is not a misconfiguration to be fixed in the console: a Migadu
# identity is a child of a mailbox and inherits its domain, so the wetwijzer
# mailbox can never be authorised for another domain. The supported route is to
# authenticate as each brand's OWN mailbox.
#
# Hence the single rule this class exists to enforce: the from address and the
# credentials are chosen as ONE decision. Picking a brand address without that
# brand's credentials produces a 550 for every message, which is precisely the
# defect this replaces - the previous code chose the address from the user's
# locale and always authenticated as wetwijzer.
#
# WHY BRAND AND NOT LOCALE
# ------------------------
# The old code keyed the sender off user.locale. SiteBrand says why that is
# wrong, in its own words: "Locale is NOT brand: a user may browse WetWijzer in
# French." A reader who registered on lisloi.be should hear from lisloi.be, so
# the signal is the brand they registered on, overridable by the reader.
#
# It also silently omitted LexLibera, which is a live brand: a :en user got the
# Dutch sender through a fallback branch rather than by decision.
#
# UNCONFIGURED BRANDS FALL BACK, DELIBERATELY
# -------------------------------------------
# A brand with no password in the environment falls back to the authenticated
# default identity rather than raising or sending as an address that would be
# refused. That makes the rollout incremental - add one brand's password and
# that brand starts sending as itself, with no code change and no risk to the
# others - and it means a password lost in an env edit degrades to a delivered
# mail from the wrong brand instead of silence.
class BrandMailerIdentity
  Identity = Struct.new(:brand, :from, :delivery_options, keyword_init: true) do
    # True when this mail authenticates as the brand's own mailbox rather than
    # falling back to the default account.
    def branded?
      !delivery_options.nil?
    end
  end

  DEFAULT_BRAND = 'wetwijzer'
  # The reader's chosen default portal, set in account settings.
  PREFERENCE_KEY = 'default_portal'

  class << self
    # @param user [User, nil]
    # @return [Identity] never nil; always something the SMTP account may send
    def for_user(user)
      for_brand(brand_for(user))
    end

    # @param brand [String, nil] a SiteBrand key
    # @return [Identity]
    def for_brand(brand)
      brand = brand.to_s
      options = delivery_options_for(brand)
      return Identity.new(brand: brand, from: address_for(brand), delivery_options: options) if options

      Identity.new(brand: DEFAULT_BRAND, from: default_from, delivery_options: nil)
    end

    # The reader's own choice of default portal first, then the portal they
    # registered on, then their language, then the default.
    #
    # OWNER DECISION 2026-09-09: store whichever portal was used to register,
    # changeable afterwards in account settings. So registration wins whenever
    # it is recorded - no second-guessing it from the reader's language.
    #
    # The tradeoff was raised and settled rather than assumed. The brand domains
    # are language-partitioned (wetwijzer.be/fr is a 404, and its own hreflang
    # for French points at lisloi.be), so a reader who signed up on wetwijzer.be
    # and later set their language to French is linked to a Dutch privacy
    # policy. An earlier revision silently redirected that reader to LisLoi;
    # this does not, because guessing on their behalf is what the setting exists
    # to avoid. They change it in settings and it sticks.
    #
    # Locale is only a FALLBACK, for the readers who have no portal recorded at
    # all - 58 of 64 accounts on 2026-09-08, all predating the column. For them
    # the language is the only signal there is.
    def brand_for(user)
      return DEFAULT_BRAND if user.nil?

      preferred = preferred_brand(user)
      return preferred if preferred

      registered = user.try(:registration_brand).presence
      return registered if SiteBrand::KEYS.include?(registered)

      SiteBrand::LOCALES.key(user.try(:locale).presence) || DEFAULT_BRAND
    end

    # No user to ask. Account-deletion mail is sent after the row is gone, so
    # locale is the only signal left. SiteBrand calls the locale/brand mapping
    # display-only and it is - but a departing reader still deserves the brand
    # they used, and the alternative here is no signal at all.
    def for_locale(locale)
      for_brand(SiteBrand::LOCALES.key(locale.to_s) || DEFAULT_BRAND)
    end

    # The address a brand sends as when it is configured to send as itself.
    def address_for(brand)
      domain = SiteBrand::CANONICAL_DOMAINS[brand.to_s]
      return default_from if domain.nil?

      "noreply@#{domain}"
    end

    # nil means "use the application-wide smtp_settings", which is the only
    # account we are certain may send.
    def delivery_options_for(brand)
      brand = brand.to_s
      return nil if brand == DEFAULT_BRAND || !SiteBrand::KEYS.include?(brand)

      password = ENV["SMTP_PASSWORD_#{brand.upcase}"].presence
      return nil if password.nil?

      {
        user_name: ENV["SMTP_USERNAME_#{brand.upcase}"].presence || address_for(brand),
        password: password,
        # HELO/EHLO domain. production.rb pins wetwijzer.be globally; a brand
        # authenticating as itself must announce itself, or SPF alignment is
        # evaluated against the wrong domain - and both LisLoi and GesetzGuide
        # publish DMARC p=reject with strict alignment (adkim=s; aspf=s).
        domain: SiteBrand::CANONICAL_DOMAINS.fetch(brand)
      }
    end

    private

    def preferred_brand(user)
      return nil unless user.respond_to?(:ui_prefs)

      value = user.ui_prefs[PREFERENCE_KEY]
      SiteBrand::KEYS.include?(value) ? value : nil
    rescue StandardError
      # A preference blob must never be able to stop a password reset.
      nil
    end

    def default_from
      ENV.fetch('MAILER_FROM', 'noreply@wetwijzer.be')
    end
  end
end
