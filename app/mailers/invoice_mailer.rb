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

    resolve_locale_context(user)
    attach_invoice_files(invoice)

    I18n.with_locale(@locale) do
      mail(
        to: user.email,
        from: @billing_email,
        subject: email_subject
      )
    end
  end

  private

  def resolve_locale_context(user)
    @locale = (user.try(:invoice_locale).presence || user.locale.presence || 'nl').to_sym
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
        content: File.read(invoice.pdf_path, mode: 'rb')
      }
    end

    return unless @is_b2b && invoice.xml_exists?

    attachments["#{file_prefix}_#{@invoice_number}.xml"] = {
      mime_type: 'application/xml',
      content: File.read(invoice.xml_path, mode: 'rb')
    }
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
