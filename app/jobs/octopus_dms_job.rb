# frozen_string_literal: true

# Background job to push invoice documents (PDF + XML) to Octopus DMS.
# Replaces the previous raw Thread.new approach in InvoicesController#push_all_to_dms
# with reliable background processing and automatic retries.
#
# Usage:
#   OctopusDmsJob.perform_later(invoice)
#
# Retries 3 times with exponential backoff on service errors.
class OctopusDmsJob < ApplicationJob
  queue_as :default

  retry_on OctopusFileImportService::FileImportError,
           wait: :polynomially_longer,
           attempts: 3 do |job, error|
    Rails.logger.error("[OctopusDmsJob] All retries exhausted for #{job.arguments.first&.invoice_number}: #{error.message}")
  end

  retry_on Net::OpenTimeout, Net::ReadTimeout,
           wait: 30.seconds,
           attempts: 2

  discard_on ActiveJob::DeserializationError

  def perform(platform_invoice)
    return unless OctopusFileImportService.enabled?

    service = OctopusFileImportService.new
    results = service.import_invoice_documents(platform_invoice)

    parts = []
    parts << 'XML' if results[:xml]
    parts << 'PDF' if results[:pdf]

    Rails.logger.info("[OctopusDmsJob] Invoice #{platform_invoice.invoice_number}: #{parts.any? ? "#{parts.join(' + ')} uploaded" : 'no files found'}")
  end
end
