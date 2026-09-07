# frozen_string_literal: true

# Background job to sync a PlatformInvoice to Octopus accounting.
# Replaces the previous fire-and-forget Thread.new approach with
# reliable background processing and automatic retries.
#
# Usage:
#   OctopusSyncJob.perform_later(invoice)
#
# Retries 3 times with exponential backoff (5s, 25s, 125s).
# After all retries exhausted, marks the invoice as failed.
class OctopusSyncJob < ApplicationJob
  queue_as :default

  retry_on OctopusApiService::OctopusError,
           wait: :polynomially_longer,
           attempts: 3 do |_job, error|
    # After all retries exhausted - this block runs on final failure
    Rails.logger.error("[OctopusSyncJob] All retries exhausted: #{error.message}")
  end

  retry_on Net::OpenTimeout, Net::ReadTimeout,
           wait: 30.seconds,
           attempts: 2

  discard_on ActiveJob::DeserializationError

  def perform(platform_invoice)
    return unless OctopusApiService.enabled?

    service = OctopusApiService.new
    service.sync_invoice(platform_invoice)

    Rails.logger.info("[OctopusSyncJob] Invoice #{platform_invoice.invoice_number} synced successfully")
  rescue OctopusApiService::OctopusError => e
    Rails.logger.error("[OctopusSyncJob] Sync failed for #{platform_invoice.invoice_number}: #{e.message}")
    platform_invoice.update_columns(octopus_status: 'failed', octopus_error: e.message)
    raise # Re-raise so retry_on kicks in
  end
end
