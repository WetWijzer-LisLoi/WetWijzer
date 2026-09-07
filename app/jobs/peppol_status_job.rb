# frozen_string_literal: true

# Recurring job that polls Octopus for PEPPOL delivery status updates.
# Checks all invoices with octopus_status 'peppol_sent' and updates
# their status to 'peppol_delivered' once confirmed by Octopus.
#
# Scheduled to run every 4 hours via config/recurring.yml.
# Can also be triggered manually from the admin interface.
class PeppolStatusJob < ApplicationJob
  queue_as :default

  def perform
    return unless OctopusApiService.enabled?

    invoices = PlatformInvoice.where(octopus_status: 'peppol_sent')
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
    response = service.get_delivery_status(invoice.octopus_invoice_key)
    return unless response.is_a?(Array) || response.is_a?(Hash)

    # Octopus returns delivery state per invoice key
    status = extract_delivery_status(response)

    case status
    when 'delivered', 'accepted'
      invoice.update!(octopus_status: 'peppol_delivered')
      Rails.logger.info("[PeppolStatusJob] #{invoice.invoice_number} → peppol_delivered")
    when 'rejected', 'failed'
      invoice.update!(
        octopus_status: 'failed',
        octopus_error: "PEPPOL delivery #{status}: #{extract_error(response)}"
      )
      Rails.logger.warn("[PeppolStatusJob] #{invoice.invoice_number} → failed (#{status})")
    end
    # 'pending' / 'sent' - no update needed, check again next cycle
  end

  def extract_delivery_status(response)
    entry = response.is_a?(Array) ? response.first : response
    return nil unless entry.is_a?(Hash)

    (entry['deliveryState'] || entry['status'])&.downcase
  end

  def extract_error(response)
    entry = response.is_a?(Array) ? response.first : response
    return nil unless entry.is_a?(Hash)

    entry['errorMessage'] || entry['description']
  end
end
