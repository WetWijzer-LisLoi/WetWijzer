# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM', 'noreply@wetwijzer.be')
  layout 'mailer'
  helper BrandingHelper
  # AFTER BrandingHelper, so its locale-keyed site_name/site_url and its
  # request-dependent contact_email are overridden for mail only.
  helper MailerBrandingHelper

  # WHICH SITE THE LINKS POINT AT
  #
  # production.rb pins config.action_mailer.default_url_options to
  # host: 'wetwijzer.be' for every message, and every mailer builds its links
  # with _url helpers. So a reader who registered on lisloi.be received a
  # confirmation link to wetwijzer.be and, on clicking it, landed on a site
  # they had never seen. That is a worse experience than the From line: the
  # sender is a detail in a header, the link is the thing they are asked to
  # act on.
  #
  # This is deliberately INDEPENDENT of the sender brand. Whether we can
  # authenticate as noreply@lisloi.be is a Migadu question; where the reader
  # should land is not, and a mail sent from the fallback address must still
  # link to the reader's own site. Hence a separate ivar - the sender may fall
  # back to wetwijzer while the links stay on lisloi.be.
  #
  # Set in process rather than in each mailer method because the _url helpers
  # are called in the method BODY, before any shared helper runs.
  def process(method_name, *args)
    reader = args.first
    @reader_brand = BrandMailerIdentity.brand_for(reader.is_a?(User) ? reader : nil)
    super
  end

  # Not calling super: the class attribute is the whole of the configured
  # value, and reading it directly keeps this readable when it is overridden
  # per environment.
  # Subjects are translated HERE rather than in a view, so the view helper
  # cannot supply the brand for them. Same contract: %{brand} resolves to the
  # reader's brand unless a caller passes its own.
  def t(key, **)
    super(key, brand: SiteBrand::LABELS.fetch(reader_brand), **)
  end

  def reader_brand
    SiteBrand::KEYS.include?(@reader_brand.to_s) ? @reader_brand.to_s : BrandMailerIdentity::DEFAULT_BRAND
  end

  def default_url_options
    configured = self.class.default_url_options || {}
    host = SiteBrand::CANONICAL_DOMAINS[@reader_brand]
    host.present? ? configured.merge(host: host) : configured
  end

  private

  # Shared pattern: set @locale from user and wrap mail() in I18n.with_locale
  # Eliminates 6 repetitions of the same locale-wrapping boilerplate across mailers.
  #
  # @param user [User] user whose locale determines the email language
  # @param subject_key [String] I18n key for the email subject
  # @param subject_opts [Hash] interpolation options for the subject translation
  # @yield optional block for additional mail options
  # @return [Mail::Message]
  def localized_mail(user, subject_key, subject_opts: {}, **mail_opts)
    @user = user
    @locale = user.locale || 'nl'
    # NOTE: identity.brand is the mailbox we AUTHENTICATE as, which falls back
    # to wetwijzer whenever a brand has no password configured. It is not the
    # reader's portal - that is @reader_brand, set in process, and it is what
    # the branding and the links follow. Keeping the two apart is the whole
    # point: a LisLoi reader gets LisLoi branding today even though the mail
    # still leaves from noreply@wetwijzer.be.
    identity = BrandMailerIdentity.for_user(user)

    I18n.with_locale(@locale) do
      mail(delivery_overrides(identity).merge(
        to: user.email,
        from: identity.from,
        subject: t(subject_key, **subject_opts)
      ).merge(mail_opts))
    end
  end

  # Kept for the one caller that has no user row left to ask (deletion_completed).
  # @param locale [String, Symbol]
  # @return [String] a sender the account may actually use
  def noreply_email(locale = 'nl')
    BrandMailerIdentity.for_locale(locale).from
  end

  # Per-message SMTP credentials, or nothing at all.
  #
  # ActionMailer merges delivery_method_options into the configured
  # smtp_settings for this message only, so an unconfigured brand simply keeps
  # the application-wide account. Returning {} rather than a nil value matters:
  # passing delivery_method_options: nil would blank the settings.
  def delivery_overrides(identity)
    return {} unless identity.branded?

    { delivery_method_options: identity.delivery_options }
  end
end
