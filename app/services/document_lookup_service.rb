# frozen_string_literal: true

class DocumentLookupService
  BATCH_SIZE = 1000

  class << self
    def update_all
      new.update_all
    end
  end

  def update_all
    Rails.logger.info "Starting document lookup update at #{Time.current}"
    start_time = Time.current
    processed = process_all_batches
    log_completion(processed, start_time)
    processed
  rescue StandardError => e
    log_error(e)
    raise
  end

  def process_all_batches
    processed = 0
    Content.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      lookups = process_batch(batch)
      next if lookups.empty?

      upsert_lookups(lookups)
      processed += lookups.size
    end
    processed
  end

  def log_completion(processed, start_time)
    duration = Time.current - start_time
    Rails.logger.info "Updated #{processed} document lookups in #{duration.round(2)} seconds"
  end

  def log_error(error)
    Rails.logger.error "Error updating document lookups: #{error.message}"
    Rails.logger.error error.backtrace.join("\n")
  end

  private

  # Processes a batch of Content records and returns an array of lookup hashes
  def process_batch(batch)
    batch.each_with_object([]) do |content, acc|
      next unless content.introd.present?

      acc.concat(build_lookups_for_content(content))
    end
  end

  # Builds lookup entries for a single Content record
  def build_lookups_for_content(content)
    doc_numbers = extract_document_numbers(content.introd)
    return [] if doc_numbers.empty?

    now = Time.current
    doc_numbers.map do |doc_number|
      {
        document_number: doc_number,
        numac: content.legislation_numac,
        content_id: content.id,
        language_id: content.language_id,
        created_at: now,
        updated_at: now
      }
    end
  end

  # Performs the upsert for the batch of lookups
  def upsert_lookups(lookups)
    DocumentNumberLookup.upsert_all(
      lookups,
      unique_by: :index_document_number_lookups_on_document_number,
      update_only: %i[numac content_id updated_at]
    )
  end

  def extract_document_numbers(text)
    # Accept alphanumeric suffixes after the slash to cover entries like 2014-04-25/M4
    text.scan(%r{\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+}).uniq
  end
end
