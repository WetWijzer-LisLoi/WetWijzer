# frozen_string_literal: true

class InvoiceMailer < ApplicationMailer
  helper BrandingHelper

  # Locale-aware billing emails per brand
  BILLING_EMAILS = {
    nl: 'billing@wetwijzer.be',
    fr: 'billing@lisloi.be',
    de: 'billing@gesetzguide.be',
    en: 'billing@wetwijzer.be'
  }.freeze

  SITE_NAMES = {
    nl: 'WetWijzer',
    fr: 'LisLoi',
    de: 'GesetzGuide',
    en: 'WetWijzer'
  }.freeze

  TAGLINES = {
    nl: 'Juridisch AI-platform',
    fr: 'Plateforme juridique IA',
    de: 'Juristische KI-Plattform',
    en: 'Legal AI Platform'
  }.freeze

  # File prefix per locale (matches translations.py)
  FILE_PREFIXES = {
    nl: 'factuur',
    fr: 'facture',
    de: 'rechnung',
    en: 'invoice'
  }.freeze

  # Send a generated invoice PDF to the customer
  #
  # @param user [User] the invoice recipient
  # @param invoice [PlatformInvoice] the invoice record with pdf_path
  def send_invoice(user, invoice)
    @user = user
    @invoice = invoice
    @invoice_number = invoice.invoice_number
    @total = invoice.total_euros
    # Provider-linked sales invoices are created only after a payment has been
    # verified and fulfilled. InvoiceService renders those same documents with
    # `--settled`, so the email must not present their OGM as a new payment
    # instruction. Credit notes and chargeback reversals are settled accounting
    # adjustments, not paid sales invoices.
    @paid_before_issue =
      invoice.provider_payment_id.present? &&
      !invoice.credit_note? &&
      !invoice.chargeback_reversal?
    @settled_document =
      @paid_before_issue || invoice.credit_note? || invoice.chargeback_reversal?
    @payment_provider_label = payment_provider_label(invoice.payment_provider)

    resolve_locale_context(user, invoice)
    attach_invoice_files(invoice)

    I18n.with_locale(@locale) do
      # From must be the authenticated SMTP identity: Migadu rejects
      # MAIL FROM billing@... on the noreply@ account (each attempt counts
      # as a session error, so retries escalated to "421 too many errors"
      # and no invoice mail ever delivered). The brand billing address stays
      # visible as Reply-To.
      mail(
        to: user.email,
        from: email_address_with_name(ENV.fetch('MAILER_FROM', 'noreply@wetwijzer.be'), @site_name),
        reply_to: @billing_email,
        subject: email_subject
      )
    end
  end

  private

  def resolve_locale_context(user, invoice)
    # The attached PDF/XML were rendered in the invoice's persisted locale.
    # A later user-preference change must not make a resend's subject/body use
    # a different brand or language from the immutable financial document.
    @locale = (
      invoice.invoice_locale.presence ||
      user.try(:invoice_locale).presence ||
      user.locale.presence ||
      'nl'
    ).to_sym
    @site_name = SITE_NAMES[@locale] || 'WetWijzer'
    @tagline = TAGLINES[@locale] || 'Juridisch AI-platform'
    @billing_email = BILLING_EMAILS[@locale] || 'billing@wetwijzer.be'
  end

  def attach_invoice_files(invoice)
    file_prefix = FILE_PREFIXES[@locale] || 'factuur'
    @peppol_sent = invoice.octopus_synced? || invoice.octopus_status == 'peppol_sent'
    @is_b2b = invoice.customer_vat.present?

    if invoice.pdf_exists?
      attachments["#{file_prefix}_#{@invoice_number}.pdf"] = {
        mime_type: 'application/pdf',
        content: File.read(invoice.safe_pdf_path, mode: 'rb')
      }
    end

    return unless @is_b2b && invoice.xml_exists?

    attachments["#{file_prefix}_#{@invoice_number}.xml"] = {
      mime_type: 'application/xml',
      content: File.read(invoice.safe_xml_path, mode: 'rb')
    }
  end

  def payment_provider_label(provider)
    case provider.to_s.downcase
    when 'mollie' then 'Mollie'
    when 'stripe' then 'Stripe'
    when 'crypto', 'coingate' then 'CoinGate'
    else
      provider.to_s.presence&.titleize
    end
  end

  # Locale-specific subject lines
  def email_subject
    case @locale
    when :fr then "#{@site_name} Facture #{@invoice_number}"
    when :de then "#{@site_name} Rechnung #{@invoice_number}"
    when :en then "#{@site_name} Invoice #{@invoice_number}"
    else "#{@site_name} Factuur #{@invoice_number}"
    end
  end
end
