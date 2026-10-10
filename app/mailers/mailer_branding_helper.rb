# frozen_string_literal: true

# Brand identity for a transactional mail: the name, the site and the contact
# address the reader should see.
#
# WHY NOT BrandingHelper
# ----------------------
# BrandingHelper answers these same questions for web pages, but from inputs a
# mailer either lacks or should not use:
#
#   * `contact_email` reads `request.host`, and a mailer has no request at all.
#   * `site_name` and `site_url` switch on `I18n.locale`. Locale is language,
#     not brand - SiteBrand says so in its own words: "Locale is NOT brand: a
#     user may browse WetWijzer in French." Keyed off locale, a French-speaking
#     WetWijzer reader is greeted as LisLoi, and a LisLoi reader whose account
#     is set to Dutch is greeted as WetWijzer. The second case is not
#     hypothetical: it is what the first brand test produced.
#
# So these read the brand ApplicationMailer resolved for this reader
# (@reader_brand) and fall back to WetWijzer when there is none, which is the
# common case today: 58 of 64 accounts predate the registration_brand column.
#
# Included AFTER BrandingHelper in ApplicationMailer, so these definitions win
# for mail without altering a single web page.
#
# WHY THIS FILE LIVES IN app/mailers AND NOT app/helpers
# -------------------------------------------------------
# Rails includes every module under app/helpers in every controller's views
# (helper :all), in file-name order. From app/helpers this module came after
# BrandingHelper and its site_name, site_url, contact_email and t overrode
# the web versions on every page of every brand: with no @reader_brand in a
# web view, mail_brand fell back to WetWijzer, and lisloi.be and
# gesetzguide.be greeted their readers as "WetWijzer" with info@wetwijzer.be
# as the contact address (noticed on the lisloi chatbot heading, 2026-10-04).
# app/mailers is an autoload root, so the constant still resolves for the
# explicit `helper MailerBrandingHelper` in ApplicationMailer, and nothing
# scans it for web helpers.
module MailerBrandingHelper
  # LexLibera's inbox lives on the Praxis domain. Preserved from
  # BrandingHelper#contact_email rather than "corrected" to the canonical
  # domain, because that mapping is deliberate.
  CONTACT_EMAILS = {
    'wetwijzer' => 'info@wetwijzer.be',
    'lisloi' => 'info@lisloi.be',
    'gesetzguide' => 'info@gesetzguide.be',
    'lexlibera' => 'info@praxislegal.be'
  }.freeze

  def mail_brand
    brand = @reader_brand.to_s
    SiteBrand::KEYS.include?(brand) ? brand : BrandMailerIdentity::DEFAULT_BRAND
  end

  def site_name
    SiteBrand::LABELS.fetch(mail_brand)
  end

  def site_url
    "https://#{SiteBrand::CANONICAL_DOMAINS.fetch(mail_brand)}"
  end

  def contact_email
    CONTACT_EMAILS.fetch(mail_brand)
  end

  # Every mailer string that names the brand now carries %{brand} instead of a
  # baked-in name, so one set of translations serves all four brands and the
  # language stays a separate axis from the identity.
  #
  # Supplying it here means no view has to remember. An explicit brand: still
  # wins, and I18n ignores an interpolation a string does not use, so passing
  # it to every key is safe.
  #
  # BOTH names are defined on purpose: ActionView aliases `t` to `translate`,
  # and a Ruby alias binds the method rather than the name, so overriding only
  # `translate` would leave every `t` call in a view going to the original.
  def translate(key, **)
    super(key, brand: site_name, **)
  end

  def t(key, **)
    translate(key, **)
  end
end
