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
    processed = process_all_lookups
    log_completion(processed, start_time)
    processed
  rescue StandardError => e
    log_error(e)
    raise
  end

  def process_all_lookups
    # Build a mapping from document number (Dossiernummer) to NUMAC
    # by extracting Dossiernummer from each law's introd field
    @doc_to_numac = build_document_number_mapping
    Rails.logger.info "Built document number mapping with #{@doc_to_numac.size} entries"

    # Now create lookup records for all document numbers found in references
    processed = 0
    Content.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      lookups = process_batch(batch)
      next if lookups.empty?

      upsert_lookups(lookups)
      processed += lookups.size
    end
    processed
  end

  # Extracts Dossiernummer from each law's introd field and builds a mapping
  # from document number to NUMAC
  def build_document_number_mapping
    mapping = {}

    Content.where.not(introd: [nil, '']).find_each do |content|
      # Extract Dossiernummer from introd
      # Pattern: <p><strong>Dossiernummer:</strong>  2007-04-25/32</p>
      # or: Dossiernummer: 2007-04-25/32
      dossiernummer = extract_dossiernummer(content.introd)
      next unless dossiernummer

      # Map this document number to the content's legislation
      mapping[dossiernummer] = {
        numac: content.legislation_numac,
        language_id: content.language_id,
        content_id: content.id
      }
    end

    mapping
  end

  def extract_dossiernummer(introd)
    return nil if introd.blank?

    # Try to extract Dossiernummer from the introd HTML
    # Pattern: Dossiernummer:</strong>  2007-04-25/32
    # or: Dossiernummer:  2007-04-25/32
    match = introd.match(%r{Dossiernummer:?\s*</strong>?\s*(\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+)}i)
    return match[1] if match

    # Alternative pattern without </strong>
    match = introd.match(%r{Dossiernummer:\s*(\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+)}i)
    match&.[](1)
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

  # Builds lookup entries for document numbers found in a content's introd
  def build_lookups_for_content(content)
    doc_numbers = extract_document_numbers(content.introd)
    return [] if doc_numbers.empty?

    now = Time.current
    doc_numbers.filter_map do |doc_number|
      # Look up the actual law for this document number using our mapping
      target = @doc_to_numac[doc_number]

      if target
        {
          document_number: doc_number,
          numac: target[:numac],
          content_id: target[:content_id],
          language_id: target[:language_id],
          created_at: now,
          updated_at: now
        }
      else
        # Document number not found in our mapping - skip it
        # (better to have no link than a wrong link)
        nil
      end
    end
  end

  # Performs the upsert for the batch of lookups
  def upsert_lookups(lookups)
    DocumentNumberLookup.upsert_all(
      lookups,
      unique_by: :index_document_number_lookups_on_document_number,
      update_only: %i[numac content_id language_id updated_at]
    )
  end

  def extract_document_numbers(text)
    # Accept alphanumeric suffixes after the slash to cover entries like 2014-04-25/M4
    text.scan(%r{\d{4}-\d{2}-\d{2}/[A-Za-z0-9]+}).uniq
  end
end
