# frozen_string_literal: true

require 'open3'
require 'bigdecimal'

# Generates PDF invoices, UBL 2.1 XML (Peppol BIS 3.0), and accounting CSV
# by shelling out to the Python invoice_generator.py package.
#
# Usage:
#   InvoiceService.generate_for_subscription_payment(user: user, payment: payment)
#   InvoiceService.generate_for_credit_purchase(user: user, purchase: purchase)
class InvoiceService
  PYTHON = '/usr/bin/python3'
  INVOICING_DIR = Rails.root.join('lib', 'invoicing')
  GENERATOR = INVOICING_DIR.join('invoice_generator.py')

  # Output directory - use Hetzner volume for persistence
  OUTPUT_DIR = ENV.fetch('INVOICE_OUTPUT_DIR') do
    Rails.root.join('storage', 'invoices').to_s
  end

  class InvoiceError < StandardError; end

  # Admin regeneration and background retries share the same persisted
  # commercial payload. Exposing only validated copies keeps every renderer on
  # the exact lines, period, tax basis, and references claimed with the number.
  def self.generator_payload_for!(invoice)
    payload = invoice.document_payload
    raise InvoiceError, 'invoice has no immutable document payload' if payload.blank?

    payload = payload.deep_stringify_keys
    validate_document_payload!(payload)
    payload
  end

  def self.append_generator_payload_args!(args, payload)
    payload = payload.deep_stringify_keys
    validate_document_payload!(payload)
    append_document_payload_args!(args, payload)
  end

  # Generate an invoice from WetWijzer's immutable, verified payment snapshot.
  # Mollie supplies payments rather than provider-generated invoice lines, so
  # the locally recorded amount and service period are the accounting source.
  def self.generate_for_subscription_payment(
    user:,
    payment:,
    payment_provider: 'mollie',
    provider_payment_id: nil
  )
    return unless user.subscription
    return unless payment&.fulfilled_at?
    provider_payment_id ||= payment.try(:mollie_payment_id)

    lines = [{
      description: 'WetWijzer Pro - Maandabonnement',
      quantity: 1,
      unit: 'maand',
      unit_price: (payment.amount_cents.to_f / 100).round(2)
    }]
    generate(
      user: user,
      lines: lines,
      invoice_type: 'subscription',
      payment_provider: payment_provider,
      provider_payment_id: provider_payment_id,
      period_start: payment.service_period_start&.to_date,
      period_end: payment.service_period_end&.to_date
    )
  end

  # Generate invoice for a one-time credit purchase
  def self.generate_for_credit_purchase(
    user:,
    purchase:,
    payment: nil,
    payment_provider: nil,
    provider_payment_id: nil
  )
    pkg = CreditPurchase::PACKAGES[purchase.package]
    return unless pkg
    if payment &&
       (
         payment.credit_purchase_id != purchase.id ||
         payment.user_id != user.id ||
         payment.amount_cents.to_i <= 0
       )
      raise InvoiceError, 'credit-purchase payment contract is invalid'
    end
    payment_provider ||= purchase.payment_method
    provider_payment_id ||= purchase.mollie_payment_id
    charged_amount_cents = payment&.amount_cents || purchase.amount_cents

    lines = [{
      description: "WetWijzer AI Credits - #{pkg[:label]}",
      quantity: 1,
      unit: 'pakket',
      unit_price: (charged_amount_cents.to_f / 100).round(2)
    }]

    generate(
      user: user,
      lines: lines,
      invoice_type: 'credit_purchase',
      payment_provider: payment_provider,
      provider_payment_id: provider_payment_id
    )
  end

  # Generate a credit note (creditnota) for a refund
  def self.generate_credit_note(original_invoice:, refund_amount_cents: nil, reason: nil, credit_note: nil)
    user = original_invoice.user
    subscription = user&.subscription
    refund_cents =
      credit_note&.total_cents ||
      refund_amount_cents ||
      original_invoice.total_cents
    if original_invoice.total_cents.to_i <= 0 || refund_cents.to_i <= 0 || refund_cents.to_i > original_invoice.total_cents.to_i
      raise InvoiceError, 'credit note refund amount is invalid'
    end

    # Accounting invoices deliberately outlive an erased account. Generate a
    # later provider refund from the retained invoice snapshot rather than
    # dereferencing a User/Subscription that may no longer exist.
    retained_customer_name = original_invoice.customer_name.presence ||
                             (user && customer_name(user, subscription)) ||
                             original_invoice.customer_email.presence || 'Klant'
    retained_customer_address = original_invoice.customer_address.to_s
    retained_customer_vat = original_invoice.customer_vat.to_s
    retained_customer_email = original_invoice.customer_email.presence || user&.email.to_s
    retained_customer_country =
      original_invoice.customer_country.presence ||
      subscription&.billing_country.presence ||
      'BE'
    retained_invoice_locale =
      original_invoice.invoice_locale.presence ||
      invoice_locale(user)

    requested_payload = build_document_payload(
      lines: [{
        description: "Creditnota #{original_invoice.invoice_number}",
        quantity: 1,
        unit: 'stuk',
        # Refund amounts are provider-confirmed VAT-inclusive cents. Let the
        # generator derive a Peppol-valid tax split plus any explicit payable
        # rounding, instead of recomputing from a mutable original invoice.
        unit_price: -(refund_cents.to_f / 100).round(2)
      }],
      prices_include_vat: true,
      original_invoice_number: original_invoice.invoice_number
    )

    # These figures reserve the accounting amount before file generation. The
    # exact Peppol split is written from the successful generator result.
    subtotal = original_invoice.subtotal_cents
    vat = original_invoice.vat_cents
    if refund_cents != original_invoice.total_cents
      ratio = refund_cents.to_f / original_invoice.total_cents
      subtotal = (subtotal * ratio).round
      vat = [refund_cents - subtotal, 0].max
    end

    credit_note ||= reserve_credit_note!(
      original_invoice: original_invoice,
      user: user,
      refund_cents: refund_cents,
      subtotal: subtotal,
      vat: vat,
      reason: reason,
      customer_name: retained_customer_name,
      customer_vat: retained_customer_vat,
      customer_email: retained_customer_email,
      customer_address: retained_customer_address,
      customer_country: retained_customer_country,
      invoice_locale: retained_invoice_locale,
      document_payload: requested_payload
    )
    return credit_note if %w[generated sent peppol_sent].include?(credit_note.status)
    credit_note.update!(status: 'reserving') if credit_note.status == 'failed'
    raise InvoiceError, 'credit note reservation is not ready' unless credit_note.status == 'reserving'

    credit_note_number = credit_note.invoice_number
    document_payload = persisted_document_payload!(credit_note, requested_payload)
    unless document_payload.fetch('expected_total_cents') == credit_note.total_cents
      raise InvoiceError, 'credit note payload does not match its reserved adjustment amount'
    end

    locale = credit_note.invoice_locale.presence || retained_invoice_locale
    args = [
      PYTHON, GENERATOR.to_s,
      '--number', credit_note_number,
      '--customer', credit_note.customer_name,
      '--address', credit_note.customer_address.to_s,
      '--vat', credit_note.customer_vat.to_s,
      '--email', credit_note.customer_email.to_s,
      '--output', OUTPUT_DIR,
      '--locale', locale,
      '--invoice-date', credit_note.created_at.to_date.iso8601,
      '--credit-note',
      '--original-number', document_payload.fetch('original_invoice_number'),
      '--buyer-reference', credit_note.customer_name,
      '--customer-country', credit_note.customer_country.presence || retained_customer_country,
      '--settled',
      '--json'
    ]
    append_document_payload_args!(args, document_payload)

    stdout, stderr, status = Open3.capture3(*args)

    unless status.success?
      error_msg = "Credit note generation failed (exit #{status.exitstatus}): #{stderr}"
      Rails.logger.error(error_msg)
      raise InvoiceError, error_msg
    end

    result = JSON.parse(stdout, symbolize_names: true)
    generated_total_cents = (result.fetch(:total).abs * 100).round
    unless generated_total_cents == document_payload.fetch('expected_total_cents')
      raise InvoiceError, 'credit note document total does not match the provider adjustment'
    end

    credit_note.update!(
      subtotal_cents: (result.fetch(:subtotal).abs * 100).round,
      vat_cents: (result.fetch(:vat_amount).abs * 100).round,
      total_cents: generated_total_cents,
      pdf_path: result[:pdf_path],
      xml_path: result[:xml_path],
      status: 'generated'
    )

    # Sync to Octopus
    OctopusSyncJob.perform_later(credit_note) if OctopusApiService.enabled?

    # An erased account has no authenticated mail recipient. Keep the retained
    # credit note generated (and available to accounting/Octopus) without
    # trying to recreate or dereference the deleted user.
    if user
      InvoiceMailer.send_invoice(user, credit_note).deliver_later
      credit_note.mark_sent!
    end

    Rails.logger.info("Credit note #{credit_note_number} generated for #{original_invoice.invoice_number}")
    credit_note
  rescue InvoiceError
    credit_note&.update_columns(status: 'failed')
    raise
  rescue StandardError => e
    credit_note&.update_columns(status: 'failed')
    Rails.logger.error("Credit note error: #{e.class}")
    raise InvoiceError, "credit note generation failed: #{e.class}"
  end

  # A provider-confirmed chargeback reversal restores money after a credit note
  # has already reduced the books. Preserve that credit note and issue one
  # positive correction invoice for the exact restored delta, linked to both
  # the original sale and every credit note consumed by this reversal.
  def self.generate_chargeback_reversal_document(
    original_invoice:,
    adjustment:,
    referenced_credit_notes:,
    correction_invoice: nil
  )
    unless adjustment&.chargeback_reversal? &&
           adjustment.delta_amount_cents.to_i.positive?
      raise InvoiceError, 'chargeback reversal adjustment is invalid'
    end
    credit_notes = Array(referenced_credit_notes).uniq(&:id)
    if credit_notes.empty? ||
       credit_notes.any? { |document| !document.credit_note? || document.original_invoice_id != original_invoice.id }
      raise InvoiceError, 'chargeback reversal credit-note references are incomplete'
    end

    user = original_invoice.user
    subscription = user&.subscription
    restored_cents = adjustment.delta_amount_cents.to_i
    if original_invoice.total_cents.to_i <= 0 || restored_cents > original_invoice.total_cents.to_i
      raise InvoiceError, 'chargeback reversal amount is invalid'
    end

    retained_customer_name = original_invoice.customer_name.presence ||
                             (user && customer_name(user, subscription)) ||
                             original_invoice.customer_email.presence || 'Klant'
    retained_customer_address = original_invoice.customer_address.to_s
    retained_customer_vat = original_invoice.customer_vat.to_s
    retained_customer_email = original_invoice.customer_email.presence || user&.email.to_s
    retained_customer_country =
      original_invoice.customer_country.presence ||
      subscription&.billing_country.presence ||
      'BE'
    retained_invoice_locale =
      original_invoice.invoice_locale.presence ||
      invoice_locale(user)
    reason = "Mollie chargeback_reversal (adjustment ##{adjustment.id})"
    references = [original_invoice.invoice_number] + credit_notes.map(&:invoice_number)
    description =
      "Herstel chargeback #{original_invoice.invoice_number} — " \
      "creditnota('s) #{credit_notes.map(&:invoice_number).join(', ')}"
    requested_payload = build_document_payload(
      lines: [{
        description: description,
        quantity: 1,
        unit: 'stuk',
        unit_price: (restored_cents.to_f / 100).round(2)
      }],
      prices_include_vat: true,
      references: references,
      original_invoice_number: original_invoice.invoice_number
    )

    correction_invoice ||= reserve_chargeback_reversal_invoice!(
      original_invoice: original_invoice,
      user: user,
      restored_cents: restored_cents,
      reason: reason,
      customer_name: retained_customer_name,
      customer_vat: retained_customer_vat,
      customer_email: retained_customer_email,
      customer_address: retained_customer_address,
      customer_country: retained_customer_country,
      invoice_locale: retained_invoice_locale,
      document_payload: requested_payload
    )
    return correction_invoice if %w[generated sent peppol_sent].include?(correction_invoice.status)
    correction_invoice.update!(status: 'reserving') if correction_invoice.status == 'failed'
    unless correction_invoice.status == 'reserving'
      raise InvoiceError, 'chargeback reversal reservation is not ready'
    end

    document_payload = persisted_document_payload!(
      correction_invoice,
      requested_payload
    )
    unless document_payload.fetch('expected_total_cents') == restored_cents
      raise InvoiceError, 'chargeback reversal payload does not match its ledger adjustment'
    end
    args = [
      PYTHON, GENERATOR.to_s,
      '--number', correction_invoice.invoice_number,
      '--customer', correction_invoice.customer_name,
      '--address', correction_invoice.customer_address.to_s,
      '--vat', correction_invoice.customer_vat.to_s,
      '--email', correction_invoice.customer_email.to_s,
      '--output', OUTPUT_DIR,
      '--locale', correction_invoice.invoice_locale.presence || retained_invoice_locale,
      '--invoice-date', correction_invoice.created_at.to_date.iso8601,
      '--correction-invoice',
      '--buyer-reference', correction_invoice.customer_name,
      '--customer-country', correction_invoice.customer_country.presence || retained_customer_country,
      '--settled',
      '--json'
    ]
    append_document_payload_args!(args, document_payload)

    stdout, stderr, status = Open3.capture3(*args)
    unless status.success?
      error_msg = "Chargeback reversal generation failed (exit #{status.exitstatus}): #{stderr}"
      Rails.logger.error(error_msg)
      raise InvoiceError, error_msg
    end

    result = JSON.parse(stdout, symbolize_names: true)
    correction_invoice.update!(
      subtotal_cents: (result[:subtotal] * 100).round,
      vat_cents: (result[:vat_amount] * 100).round,
      total_cents: (result[:total] * 100).round,
      pdf_path: result[:pdf_path],
      xml_path: result[:xml_path],
      ogm: result[:ogm],
      status: 'generated'
    )
    unless correction_invoice.total_cents ==
           document_payload.fetch('expected_total_cents')
      raise InvoiceError, 'chargeback reversal document total does not match the restored amount'
    end

    sync_to_octopus_async(correction_invoice) if OctopusApiService.enabled?
    if user
      InvoiceMailer.send_invoice(user, correction_invoice).deliver_later
      correction_invoice.mark_sent!
    end
    correction_invoice
  rescue InvoiceError
    correction_invoice&.update_columns(status: 'failed')
    raise
  rescue StandardError => e
    correction_invoice&.update_columns(status: 'failed')
    Rails.logger.error("Chargeback reversal document error: #{e.class}")
    raise InvoiceError, "chargeback reversal document generation failed: #{e.class}"
  end

  # Core generation method
  def self.generate(user:, lines:, invoice_type:, payment_provider: nil,
                    provider_invoice_id: nil, provider_payment_id: nil,
                    period_start: nil, period_end: nil)
    sub = user.subscription
    requested_locale = invoice_locale(user)
    requested_country = sub&.billing_country.presence || 'BE'
    requested_payload = build_document_payload(
      lines: lines,
      period_start: period_start,
      period_end: period_end,
      prices_include_vat: true
    )

    invoice = if payment_provider.present? && provider_payment_id.present?
                PlatformInvoice.find_by(
                  invoice_type: invoice_type,
                  payment_provider: payment_provider,
                  provider_payment_id: provider_payment_id
                )
              end
    return invoice if invoice && %w[generated sent peppol_sent].include?(invoice.status)

    invoice ||= reserve_invoice!(
      user: user, sub: sub, invoice_type: invoice_type,
      payment_provider: payment_provider,
      provider_invoice_id: provider_invoice_id,
      provider_payment_id: provider_payment_id,
      customer_country: requested_country,
      invoice_locale: requested_locale,
      document_payload: requested_payload,
      expected_total_cents: requested_payload.fetch('expected_total_cents')
    )
    invoice.update!(status: 'reserving') if invoice.status == 'failed'
    unless invoice.status == 'reserving'
      raise InvoiceError, "invoice reservation has unexpected status #{invoice.status}"
    end

    invoice_number = invoice.invoice_number
    document_payload = persisted_document_payload!(invoice, requested_payload)

    # Build CLI arguments
    # The reservation is the immutable invoice identity. A retry must render
    # from these encrypted snapshots, never from a billing profile that may
    # have changed after the invoice number was claimed.
    locale = invoice.invoice_locale.presence || requested_locale
    args = [
      PYTHON, GENERATOR.to_s,
      '--number', invoice_number,
      '--customer', invoice.customer_name,
      '--address', invoice.customer_address.to_s,
      '--vat', invoice.customer_vat.to_s,
      '--email', invoice.customer_email.to_s,
      '--output', OUTPUT_DIR,
      '--locale', locale,
      '--invoice-date', invoice.created_at.to_date.iso8601,
      '--buyer-reference', invoice.customer_name,
      '--customer-country', invoice.customer_country.presence || requested_country,
      '--settled',
      '--json'
    ]
    append_document_payload_args!(args, document_payload)

    # Execute Python generator
    Rails.logger.info("Generating invoice #{invoice_number} for user #{user.id}")

    stdout, stderr, status = Open3.capture3(*args)

    unless status.success?
      error_msg = "Invoice generation failed (exit #{status.exitstatus}): #{stderr}"
      Rails.logger.error(error_msg)
      raise InvoiceError, error_msg
    end

    result = JSON.parse(stdout, symbolize_names: true)
    generated_total_cents = (result.fetch(:total).abs * 100).round
    unless generated_total_cents == document_payload.fetch('expected_total_cents')
      raise InvoiceError, 'generated invoice total does not match its immutable payment payload'
    end

    # Fill in the reserved row with the generated figures.
    # round, not to_i: (2.48 * 100).to_i == 247 (float repr truncation),
    # which stored every invoice a cent low and broke subtotal+vat==total.
    invoice.update!(
      subtotal_cents: (result[:subtotal] * 100).round,
      vat_cents: (result[:vat_amount] * 100).round,
      total_cents: generated_total_cents,
      pdf_path: result[:pdf_path],
      xml_path: result[:xml_path],
      ogm: result[:ogm],
      status: 'generated'
    )

    # Send PEPPOL e-invoice via Octopus API (replaces Storecove)
    sync_to_octopus_async(invoice) if OctopusApiService.enabled?

    # Email PDF to customer
    InvoiceMailer.send_invoice(user, invoice).deliver_later

    invoice.mark_sent!

    Rails.logger.info("Invoice #{invoice_number} generated: PDF=#{result[:pdf_path]}, Total=€#{result[:total]}")
    invoice
  rescue InvoiceError
    invoice&.update_columns(status: 'failed')
    raise # re-raise generation errors
  rescue StandardError => e
    invoice&.update_columns(status: 'failed')
    Rails.logger.error("Invoice service error for user #{user.id}: #{e.message}")
    Rails.logger.error(e.backtrace&.first(5)&.join("\n"))
    raise InvoiceError, "invoice generation failed: #{e.class}"
  end

  def self.reserve_credit_note!(original_invoice:, user:, refund_cents:, subtotal:, vat:, reason:,
                                customer_name:, customer_vat:, customer_email:, customer_address:,
                                customer_country:, invoice_locale:, document_payload:)
    attempts = 0
    begin
      PlatformInvoice.create!(
        user: user,
        invoice_number: PlatformInvoice.next_credit_note_number,
        invoice_type: 'credit_note',
        original_invoice: original_invoice,
        subtotal_cents: subtotal,
        vat_cents: vat,
        total_cents: refund_cents,
        customer_name: customer_name,
        customer_vat: customer_vat.presence,
        customer_email: customer_email.presence,
        customer_address: customer_address,
        customer_country: customer_country,
        invoice_locale: invoice_locale,
        status: 'reserving',
        refund_reason: reason,
        payment_provider: original_invoice.payment_provider,
        provider_payment_id: original_invoice.provider_payment_id,
        document_payload: document_payload
      )
    rescue ActiveRecord::RecordInvalid => e
      raise if e.record.errors[:invoice_number].blank?

      retry if (attempts += 1) < 10
      raise InvoiceError, "could not allocate a unique credit-note number after #{attempts} attempts"
    rescue ActiveRecord::RecordNotUnique
      if reason.present?
        existing = PlatformInvoice.find_by(
          invoice_type: 'credit_note',
          original_invoice_id: original_invoice.id,
          refund_reason: reason
        )
        return existing if existing
      end

      retry if (attempts += 1) < 10
      raise InvoiceError, "could not allocate a unique credit-note number after #{attempts} attempts"
    end
  end
  private_class_method :reserve_credit_note!

  def self.reserve_chargeback_reversal_invoice!(
    original_invoice:,
    user:,
    restored_cents:,
    reason:,
    customer_name:,
    customer_vat:,
    customer_email:,
    customer_address:,
    customer_country:,
    invoice_locale:,
    document_payload:
  )
    attempts = 0
    begin
      PlatformInvoice.create!(
        user: user,
        invoice_number: PlatformInvoice.next_number,
        invoice_type: 'chargeback_reversal',
        original_invoice: original_invoice,
        subtotal_cents: 0,
        vat_cents: 0,
        total_cents: restored_cents,
        customer_name: customer_name,
        customer_vat: customer_vat.presence,
        customer_email: customer_email.presence,
        customer_address: customer_address,
        customer_country: customer_country,
        invoice_locale: invoice_locale,
        status: 'reserving',
        refund_reason: reason,
        payment_provider: original_invoice.payment_provider,
        provider_payment_id: original_invoice.provider_payment_id,
        document_payload: document_payload
      )
    rescue ActiveRecord::RecordInvalid => e
      raise if e.record.errors[:invoice_number].blank?

      retry if (attempts += 1) < 10
      raise InvoiceError, "could not allocate a unique correction number after #{attempts} attempts"
    rescue ActiveRecord::RecordNotUnique
      existing = PlatformInvoice.find_by(
        invoice_type: 'chargeback_reversal',
        original_invoice_id: original_invoice.id,
        refund_reason: reason
      )
      return existing if existing

      retry if (attempts += 1) < 10
      raise InvoiceError, "could not allocate a unique correction number after #{attempts} attempts"
    end
  end
  private_class_method :reserve_chargeback_reversal_invoice!

  # Atomically claim the next invoice number by inserting the row. The unique
  # index on invoice_number is the serialization point: a colliding concurrent
  # insert raises RecordNotUnique and we retry with a fresh number. The row is
  # created 'reserving' with zero amounts and filled in once the PDF exists (or
  # marked 'failed', which keeps the number accounted for rather than leaving a
  # gap the next invoice would silently reuse).
  def self.reserve_invoice!(user:, sub:, invoice_type:, payment_provider:,
                            provider_invoice_id:, provider_payment_id:,
                            customer_country:, invoice_locale:,
                            document_payload:, expected_total_cents:)
    attempts = 0
    begin
      PlatformInvoice.create!(
        user: user,
        invoice_number: PlatformInvoice.next_number,
        invoice_type: invoice_type,
        subtotal_cents: 0, vat_cents: 0,
        total_cents: expected_total_cents,
        status: 'reserving',
        customer_name: customer_name(user, sub),
        customer_vat: sub&.vat_number,
        customer_email: user.email,
        customer_address: customer_address(sub),
        customer_country: customer_country,
        invoice_locale: invoice_locale,
        payment_provider: payment_provider,
        provider_invoice_id: provider_invoice_id,
        provider_payment_id: provider_payment_id,
        document_payload: document_payload
      )
    rescue ActiveRecord::RecordInvalid => e
      # A concurrent reservation committed the same number between our
      # next_number read and save: the uniqueness VALIDATION's pre-SELECT trips
      # first (RecordInvalid). Retry only that; re-raise any other invalidity.
      raise if e.record.errors[:invoice_number].blank?

      retry if (attempts += 1) < 10
      raise InvoiceError, "could not allocate a unique invoice number after #{attempts} attempts"
    rescue ActiveRecord::RecordNotUnique
      # A concurrent durable invoice job may have won the provider-payment
      # idempotency key. Adopt that invoice instead of allocating a second
      # accounting document for the same charge.
      if payment_provider.present? && provider_payment_id.present?
        existing = PlatformInvoice.find_by(
          invoice_type: invoice_type,
          payment_provider: payment_provider,
          provider_payment_id: provider_payment_id
        )
        return existing if existing
      end

      # Otherwise the DB unique index caught an invoice-number collision.
      retry if (attempts += 1) < 10
      raise InvoiceError, "could not allocate a unique invoice number after #{attempts} attempts"
    end
  end
  private_class_method :reserve_invoice!

  # --- Private helpers ---

  def self.build_document_payload(lines:, prices_include_vat:, period_start: nil,
                                  period_end: nil, references: [],
                                  original_invoice_number: nil)
    normalized_lines = Array(lines).map do |line|
      normalize_document_line(line)
    end
    raise InvoiceError, 'invoice document requires at least one line' if normalized_lines.empty?

    expected_total_cents = (
      normalized_lines.sum do |line|
        BigDecimal(line.fetch('quantity')) *
          BigDecimal(line.fetch('unit_price')) *
          100
      end.abs
    ).round
    raise InvoiceError, 'invoice document total must be positive' unless expected_total_cents.positive?

    {
      'version' => 1,
      'lines' => normalized_lines,
      'period_start' => period_start&.iso8601,
      'period_end' => period_end&.iso8601,
      'prices_include_vat' => !!prices_include_vat,
      'expected_total_cents' => expected_total_cents,
      'vat_rate' => 21,
      'references' => Array(references).map(&:to_s),
      'original_invoice_number' => original_invoice_number&.to_s
    }
  end
  private_class_method :build_document_payload

  def self.normalize_document_line(line)
    attributes = line.to_h.stringify_keys
    description = attributes.fetch('description').to_s.strip
    unit = attributes.fetch('unit').to_s.strip
    if description.blank? || description.match?(/[;\r\n]/) ||
       unit.blank? || unit.match?(/[;\r\n]/)
      raise InvoiceError, 'invoice line contains an invalid delimiter'
    end

    quantity = BigDecimal(attributes.fetch('quantity').to_s)
    unit_price = BigDecimal(attributes.fetch('unit_price').to_s)
    raise InvoiceError, 'invoice line quantity must be positive' unless quantity.positive?
    raise InvoiceError, 'invoice line price cannot be zero' if unit_price.zero?

    {
      'description' => description,
      'quantity' => quantity.to_s('F'),
      'unit' => unit,
      'unit_price' => unit_price.to_s('F')
    }
  rescue KeyError, ArgumentError
    raise InvoiceError, 'invoice line is incomplete'
  end
  private_class_method :normalize_document_line

  def self.persisted_document_payload!(invoice, fallback)
    if invoice.document_payload.blank?
      invoice.update!(document_payload: fallback)
    end
    payload = invoice.document_payload.deep_stringify_keys
    validate_document_payload!(payload)
    payload
  end
  private_class_method :persisted_document_payload!

  def self.validate_document_payload!(payload)
    raise InvoiceError, 'invoice payload version is unsupported' unless payload['version'] == 1
    raise InvoiceError, 'invoice payload lines are invalid' unless payload['lines'].is_a?(Array) &&
                                                                   payload['lines'].any?
    payload['lines'].each { |line| normalize_document_line(line) }
    expected_total_cents = Integer(payload['expected_total_cents'])
    raise InvoiceError, 'invoice payload total is invalid' unless expected_total_cents.positive?
    (
      Array(payload['references']) + [payload['original_invoice_number']].compact
    ).each do |reference|
      reference = reference.to_s
      raise InvoiceError, 'invoice payload reference is invalid' if reference.blank? ||
                                                               reference.match?(/[\r\n]/)
    end
    %w[period_start period_end].each do |key|
      Date.iso8601(payload[key]) if payload[key].present?
    end
    true
  rescue ArgumentError, TypeError
    raise InvoiceError, 'invoice payload is invalid'
  end
  private_class_method :validate_document_payload!

  def self.append_document_payload_args!(args, payload)
    args << '--prices-include-vat' if payload.fetch('prices_include_vat')
    payload.fetch('lines').each do |line|
      normalized = normalize_document_line(line)
      args.push(
        '--line',
        [
          normalized.fetch('description'),
          normalized.fetch('quantity'),
          normalized.fetch('unit'),
          normalized.fetch('unit_price')
        ].join(';')
      )
    end
    args.push('--period-start', payload['period_start']) if payload['period_start'].present?
    args.push('--period-end', payload['period_end']) if payload['period_end'].present?
    Array(payload['references']).each do |reference|
      args.push('--reference-number', reference)
    end
  end
  private_class_method :append_document_payload_args!

  def self.customer_name(user, sub)
    sub&.company_name.presence || user.name.presence || user.email
  end
  private_class_method :customer_name

  def self.customer_address(sub)
    return '' unless sub

    parts = [
      sub.billing_address_line1,
      sub.billing_address_line2,
      [sub.billing_postal_code, sub.billing_city].compact.join(' ')
    ].compact_blank

    parts.join(', ')
  end
  private_class_method :customer_address

  def self.sync_to_octopus_async(invoice)
    # Enqueue background job for reliable sync with automatic retries
    OctopusSyncJob.perform_later(invoice)
  end
  private_class_method :sync_to_octopus_async

  # Resolve invoice locale: explicit preference → registration locale → site default
  VALID_INVOICE_LOCALES = %w[nl fr de en].freeze

  def self.invoice_locale(user)
    # 1. Explicit invoice language preference (set in profile)
    pref = user.try(:invoice_locale)
    return pref if pref.present? && VALID_INVOICE_LOCALES.include?(pref)

    # 2. Registration locale (set at signup from site domain)
    reg = user.try(:locale)
    return reg if reg.present? && VALID_INVOICE_LOCALES.include?(reg)

    # 3. Site default
    'nl'
  end
  private_class_method :invoice_locale
end
