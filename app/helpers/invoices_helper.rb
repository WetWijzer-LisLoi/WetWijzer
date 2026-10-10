# frozen_string_literal: true

module InvoicesHelper
  # Generic Octopus bookkeeping sync is not evidence of Peppol submission.
  def invoice_peppol_state(invoice)
    case invoice.octopus_status
    when 'pending' then :pending
    when 'peppol_sending' then :sending
    when 'peppol_sent' then :submitted
    when 'peppol_delivered' then :delivered
    when 'failed' then :failed
    # A blank VAT field is not evidence that the immutable invoice belonged
    # to a consumer. Legacy/incomplete business records can be blank too.
    else invoice.customer_vat.present? ? :not_submitted : :not_determined
    end
  end

  def invoice_peppol_state_label(invoice)
    I18n.t("invoice_delivery.peppol.#{invoice_peppol_state(invoice)}")
  end
end
