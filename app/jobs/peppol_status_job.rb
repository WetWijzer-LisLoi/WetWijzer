# frozen_string_literal: true

# Recurring job that polls Octopus for PEPPOL delivery status updates.
# Checks invoices for which Octopus accepted a Peppol request.  Acceptance is
# asynchronous; only PEPPOL_SEND_OK in the delivery report confirms transport.
#
# Scheduled to run every 4 hours via config/recurring.yml.
# Can also be triggered manually from the admin interface.
class PeppolStatusJob < ApplicationJob
  queue_as :default

  def perform
    return unless OctopusApiService.enabled?

    invoices = PlatformInvoice.where(octopus_status: %w[peppol_sending peppol_sent])
                              .where.not(octopus_invoice_key: [nil, ''])

    return if invoices.empty?

    Rails.logger.info("[PeppolStatusJob] Checking delivery status for #{invoices.count} invoices")

    service = OctopusApiService.new
    service.ensure_connected!

    invoices.find_each do |invoice|
      check_delivery(service, invoice)
    rescue OctopusApiService::OctopusError => e
      Rails.logger.warn("[PeppolStatusJob] Status check failed for #{invoice.invoice_number}: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("[PeppolStatusJob] Unexpected error for #{invoice.invoice_number}: #{e.message}")
    end

    Rails.logger.info('[PeppolStatusJob] Status check complete')
  end

  private

  def check_delivery(service, invoice)
    entry = service.refresh_peppol_delivery!(invoice)
    return unless entry

    Rails.logger.info("[PeppolStatusJob] #{invoice.invoice_number} → #{invoice.octopus_status}")
  end
end
