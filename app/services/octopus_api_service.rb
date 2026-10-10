# frozen_string_literal: true

# Octopus REST API client for WetWijzer invoice integration.
#
# Handles authentication (Basic Auth), dossier token management,
# invoice creation, PEPPOL dispatch, and delivery status checking.
#
# All tokens are cached in-memory with automatic refresh on expiry.
# Session cookies are maintained across requests as required by Octopus.
#
# Usage:
#   service = OctopusApiService.new
#   service.ensure_connected!
#   service.create_invoice(invoice_data)
#   service.send_invoice_peppol(invoice_key)
#
# Environment variables:
#   OCTOPUS_SOFTWARE_HOUSE_ID  - UUID from Octopus registration
#   OCTOPUS_USERNAME           - Octopus login
#   OCTOPUS_PASSWORD           - Octopus password
#   OCTOPUS_DOSSIER_ID         - Numeric dossier ID
#   OCTOPUS_API_URL            - Base URL (default: https://service.inaras.be/octopus-rest-api/v1)
#   OCTOPUS_ENABLED            - Feature flag (default: false)
class OctopusApiService
  API_URL = ENV.fetch('OCTOPUS_API_URL', 'https://service.inaras.be/octopus-rest-api/v1')
  TOKEN_LIFETIME = 9.minutes # Refresh before the 10-minute expiry

  class OctopusError < StandardError
    attr_reader :http_code, :octopus_code, :technical_info

    def initialize(message, http_code: nil, octopus_code: nil, technical_info: nil)
      @http_code = http_code
      @octopus_code = octopus_code
      @technical_info = technical_info
      super(message)
    end
  end

  class AuthenticationError < OctopusError; end
  class DossierError < OctopusError; end
  class InvoiceError < OctopusError; end

  # A request whose result cannot safely be inferred must never be retried as a
  # new Octopus invoice.  In particular, a read timeout can happen after
  # Octopus has accepted the create request.  There is no idempotency key in
  # the documented create endpoint, so a human must reconcile that case in
  # Octopus before trying again.
  class ManualReconciliationRequired < OctopusError; end

  # The send endpoint may return HTTP 200 while selecting e-mail (or no
  # transport) for a document.  That is a completed API call, not proof of a
  # Peppol submission.  Do not retry it automatically.
  class PeppolActionRequired < OctopusError; end
  class SyncInProgress < OctopusError; end

  MANUAL_RECONCILIATION_CODE = 'OCTOPUS_MANUAL_RECONCILIATION_REQUIRED'
  PEPPOL_ACTION_REQUIRED_CODE = 'OCTOPUS_PEPPOL_ACTION_REQUIRED'
  CREATE_PREPARING_CODE = 'OCTOPUS_CREATE_PREPARING'

  def initialize
    @software_house_id = ENV.fetch('OCTOPUS_SOFTWARE_HOUSE_ID', nil)
    @username = ENV.fetch('OCTOPUS_USERNAME', nil)
    @password = ENV.fetch('OCTOPUS_PASSWORD', nil)
    @dossier_id = ENV.fetch('OCTOPUS_DOSSIER_ID', nil)&.to_i

    @auth_token = nil
    @auth_token_expires_at = nil
    @dossier_token = nil
    @dossier_token_expires_at = nil
    @cookies = {} # Session cookies required by Octopus
  end

  def self.enabled?
    ENV.fetch('OCTOPUS_ENABLED', 'false') == 'true' &&
      ENV['OCTOPUS_SOFTWARE_HOUSE_ID'].present? &&
      ENV['OCTOPUS_USERNAME'].present? &&
      ENV['OCTOPUS_PASSWORD'].present? &&
      ENV['OCTOPUS_DOSSIER_ID'].present?
  end

  # --- Authentication ---

  def authenticate!
    Rails.logger.info('[Octopus] Authenticating...')

    response = post('/authentication', {
                      username: @username,
                      password: @password
                    }, headers: { 'softwareHouseUuid' => @software_house_id }, skip_auth: true)

    @auth_token = response['token']
    @auth_token_expires_at = Time.current + TOKEN_LIFETIME

    Rails.logger.info('[Octopus] Authentication successful')
    @auth_token
  end

  def connect_dossier!
    raise DossierError, 'No dossier ID configured' unless @dossier_id

    Rails.logger.info("[Octopus] Connecting to dossier #{@dossier_id}...")

    response = post('/dossiers', nil,
                    headers: { 'authenticationToken' => @auth_token },
                    params: { 'dossierId' => @dossier_id },
                    skip_auth: true)

    @dossier_token = response['dossiertoken'] || response['dossierToken']
    @dossier_token_expires_at = Time.current + TOKEN_LIFETIME

    Rails.logger.info("[Octopus] Connected to dossier #{@dossier_id}")
    @dossier_token
  end

  # Ensures we have valid auth + dossier tokens, refreshing if needed
  def ensure_connected!
    authenticate! if auth_token_expired?
    connect_dossier! if dossier_token_expired?
  end

  # --- Invoice Operations ---

  # Create an invoice in Octopus from a PlatformInvoice record
  def create_invoice(platform_invoice)
    ensure_connected!

    # First, ensure the relation (client) exists in Octopus
    relation = find_or_create_relation(platform_invoice)

    # Get bookyear and journal info
    bookyear = current_bookyear
    journal = sell_journal(bookyear)
    vat_code = sell_vat_code_21

    raise InvoiceError, 'No active bookyear found' unless bookyear
    raise InvoiceError, 'No sell journal found' unless journal

    # Build the invoice payload
    invoice_data = build_invoice_payload(
      platform_invoice: platform_invoice,
      bookyear: bookyear,
      journal: journal,
      vat_code: vat_code,
      relation: relation
    )
    # Validate the locally-derived key before the irreversible provider call.
    # Otherwise a successfully created remote invoice could be impossible to
    # persist, select for sending, or reconcile later.
    document_key = document_key_for_payload(invoice_data)

    # Fence the irreversible call durably, not after its response. A crash,
    # malformed success response or failed local save after acceptance must
    # never let a restarted worker create the same invoice again.
    claimed = PlatformInvoice.where(id: platform_invoice.id, octopus_invoice_key: [nil, ''])
                             .update_all(
                               octopus_invoice_key: self.class.serialize_document_key(document_key),
                               octopus_status: 'failed',
                               octopus_error: "#{MANUAL_RECONCILIATION_CODE}: provider create outcome requires confirmation"
                             )
    platform_invoice.reload
    raise ManualReconciliationRequired, 'Another worker already claimed this document' unless claimed == 1

    # Octopus documents this endpoint as a 201 response with no body.  Keep the
    # exact key from our accepted request instead of guessing from an absent
    # response.
    post("/dossiers/#{@dossier_id}/invoices", invoice_data)

    Rails.logger.info("[Octopus] Invoice created for #{platform_invoice.invoice_number}")
    document_key
  rescue Timeout::Error
    # We cannot know whether the remote side created the document.  Retrying a
    # create would risk a duplicate accounting document.
    raise ManualReconciliationRequired, 'Invoice creation outcome is unknown; reconcile in Octopus before retrying'
  end

  # Create a buy/sell booking (simpler, no Invoice Module needed)
  def create_booking(platform_invoice)
    ensure_connected!

    relation = find_or_create_relation(platform_invoice)
    bookyear = current_bookyear
    journal = sell_journal(bookyear)
    vat_code = sell_vat_code_21

    raise InvoiceError, 'No active bookyear found' unless bookyear
    raise InvoiceError, 'No sell journal found' unless journal

    booking_data = build_booking_payload(
      platform_invoice: platform_invoice,
      bookyear: bookyear,
      journal: journal,
      vat_code: vat_code,
      relation: relation
    )

    # Wrap with optional attachment (the UBL XML)
    request_body = { 'buySellBookingServiceData' => booking_data }

    if platform_invoice.xml_exists?
      request_body['attachments'] = [{
        'fileName' => "#{platform_invoice.invoice_number}.xml",
        'fileData' => Base64.strict_encode64(File.binread(platform_invoice.safe_xml_path))
      }]
    end

    response = post("/dossiers/#{@dossier_id}/buysellbookings", request_body)

    Rails.logger.info("[Octopus] Booking created for #{platform_invoice.invoice_number}")
    response
  end

  # Ask Octopus to send exactly one created document.  The documented endpoint
  # takes a DocumentSelectionData object, not an `invoiceKeys` array.  A 200
  # only acknowledges processing; callers must inspect the matching status and
  # then poll the asynchronous delivery report.
  def send_invoice_peppol(document_key)
    ensure_connected!

    key = self.class.document_key_from_storage(document_key)
    raise InvoiceError, 'Octopus document key is invalid' unless key

    response = post("/dossiers/#{@dossier_id}/invoices/send", send_request_for(key))

    Rails.logger.info('[Octopus] PEPPOL send request accepted for a document')
    response
  end

  # Check PEPPOL delivery status
  def get_delivery_status(document_key)
    ensure_connected!

    key = self.class.document_key_from_storage(document_key)
    raise InvoiceError, 'Octopus document key is invalid' unless key

    post("/dossiers/#{@dossier_id}/invoices/send/report/deliverystate", document_selection_for(key))
  end

  # --- Relation Management ---

  def find_or_create_relation(platform_invoice)
    ensure_connected!

    # Try to find existing relation by VAT number
    if platform_invoice.customer_vat.present?
      relations = get_relations
      existing = relations&.find { |r| normalize_vat(r.dig('relationServiceData', 'vatNumber')) == normalize_vat(platform_invoice.customer_vat) }
      return existing.dig('relationServiceData', 'relationIdentificationServiceData') if existing
    end

    # Create new relation
    create_relation(platform_invoice)
  end

  def get_relations
    ensure_connected!
    get("/dossiers/#{@dossier_id}/relations")
  end

  def create_relation(platform_invoice)
    ensure_connected!

    relation_data = {
      'name' => platform_invoice.customer_name || 'Klant',
      'client' => true,
      'supplier' => false,
      'vatNumber' => platform_invoice.customer_vat,
      'address' => platform_invoice.customer_address,
      'email' => platform_invoice.customer_email
    }

    response = put("/dossiers/#{@dossier_id}/relations", relation_data)
    response&.dig('relationIdentificationServiceData') || response
  end

  # --- Reference Data ---

  def get_bookyears
    ensure_connected!
    get("/dossiers/#{@dossier_id}/bookyears")
  end

  def get_journals(bookyear_id)
    ensure_connected!
    get("/dossiers/#{@dossier_id}/bookyears/#{bookyear_id}/journals")
  end

  def get_vat_codes
    ensure_connected!
    get("/dossiers/#{@dossier_id}/vatcodes")
  end

  # --- Sync Orchestration ---

  # Main entry point: sync a PlatformInvoice to Octopus.
  #
  # A VAT-bearing invoice must not silently fall back to a bookkeeping-only
  # record: that would make it look accounted for while its structured B2B
  # delivery still needs action.  Once an Octopus document key is durable, all
  # retries reuse it and never create a second invoice.
  def sync_invoice(platform_invoice)
    platform_invoice.reload
    raise_manual_reconciliation!(platform_invoice) if manual_reconciliation_required?(platform_invoice)
    raise PeppolActionRequired, 'This document requires manual transport reconciliation' if peppol_action_required?(platform_invoice)
    raise SyncInProgress, 'Another worker is preparing this document; reconcile a stranded preparation before retrying' if platform_invoice.octopus_error == CREATE_PREPARING_CODE

    if (existing_key = self.class.document_key_from_storage(platform_invoice.octopus_invoice_key))
      return resume_existing_invoice!(platform_invoice, existing_key)
    end

    # A non-empty legacy or malformed key is evidence of an earlier provider
    # interaction.  It cannot be matched to the documented delivery report, so
    # creating another invoice would be unsafe.
    if platform_invoice.octopus_invoice_key.present?
      mark_manual_reconciliation!(platform_invoice)
      raise_manual_reconciliation!(platform_invoice)
    end

    # A compare-and-set is committed before any provider work. Do not put
    # network calls in a transaction: rollback would erase the create fence.
    claimed = PlatformInvoice.where(id: platform_invoice.id, octopus_invoice_key: [nil, ''],
                                    octopus_status: platform_invoice.octopus_status,
                                    octopus_error: platform_invoice.octopus_error)
                             .update_all(octopus_status: 'pending', octopus_error: CREATE_PREPARING_CODE)
    raise SyncInProgress, 'Another worker claimed this document' unless claimed == 1

    platform_invoice.reload

    begin
      ensure_connected!

      # The documented create endpoint returns 201 with no response body.  The
      # request itself contains the DocumentKey needed for sending and polling.
      invoice_key = create_invoice(platform_invoice)

      platform_invoice.update!(
        octopus_status: 'synced',
        octopus_invoice_key: self.class.serialize_document_key(invoice_key),
        octopus_synced_at: Time.current,
        octopus_error: nil
      )

      request_peppol_delivery!(platform_invoice, invoice_key) if peppol_required?(platform_invoice)

      platform_invoice
    rescue ManualReconciliationRequired
      mark_manual_reconciliation!(platform_invoice) unless manual_reconciliation_required?(platform_invoice)
      raise
    rescue PeppolActionRequired
      mark_peppol_action_required!(platform_invoice) unless platform_invoice.octopus_error.to_s.start_with?(PEPPOL_ACTION_REQUIRED_CODE)
      raise
    rescue OctopusError => e
      raise_manual_reconciliation!(platform_invoice) if manual_reconciliation_required?(platform_invoice)

      if %w[peppol_sending peppol_sent].include?(platform_invoice.octopus_status)
        platform_invoice.update!(octopus_error: 'OCTOPUS_STATUS_UNAVAILABLE')
        raise
      end
      if e.message.include?('module') || e.http_code == 403
        if peppol_required?(platform_invoice)
          mark_peppol_action_required!(platform_invoice)
          raise PeppolActionRequired, 'Invoice module unavailable; structured delivery requires action'
        end

        Rails.logger.info('[Octopus] Invoice Module not available, falling back to booking')
        fallback_to_booking(platform_invoice)
      else
        mark_failed!(platform_invoice, 'OCTOPUS_SYNC_FAILED')
        raise
      end
    end
  end

  # Return the matching documented delivery-state row for a stored document
  # key.  Never use the first row: report responses may include several
  # documents and assigning another invoice's result is materially wrong.
  def self.delivery_entry_for(response, document_key)
    key = document_key_from_storage(document_key)
    return nil unless key

    Array(response).find do |entry|
      entry.is_a?(Hash) && document_keys_match?(entry['documentKey'], key)
    end
  end

  # Return the matching immediate send result.  This is only an initiation
  # result; PEPPOL_SEND_OK in the delivery report is the later transport proof.
  def self.send_entry_for(response, document_key)
    key = document_key_from_storage(document_key)
    return nil unless key && response.is_a?(Hash)

    Array(response['sendInvoiceStatusList']).find do |entry|
      entry.is_a?(Hash) && document_keys_match?(entry['documentKey'], key)
    end
  end

  def self.document_key_from_storage(value)
    candidate = case value
                when String
                  JSON.parse(value)
                when Hash
                  value
                else
                  nil
                end
    normalize_document_key(candidate)
  rescue JSON::ParserError
    nil
  end

  def self.serialize_document_key(value)
    key = document_key_from_storage(value)
    raise ArgumentError, 'invalid Octopus document key' unless key

    JSON.generate(key)
  end

  def self.document_keys_match?(left, right)
    normalize_document_key(left) == normalize_document_key(right)
  end

  def self.normalize_document_key(value)
    return nil unless value.is_a?(Hash)

    hash = value.deep_stringify_keys
    bookyear_key = hash['bookyearKey']
    journal = hash['journal'].to_s.strip
    bookyear_id = if bookyear_key.is_a?(Hash)
                    positive_integer(bookyear_key.deep_stringify_keys['id'])
                  end
    sequence = positive_integer(hash['documentSequenceNr'])
    return nil unless bookyear_key.is_a?(Hash) && bookyear_id && journal.present? && sequence
    return nil if journal.length > 64 || journal.match?(/[[:cntrl:]]/)

    { 'bookyearKey' => { 'id' => bookyear_id }, 'journal' => journal, 'documentSequenceNr' => sequence }
  end

  def self.positive_integer(value)
    case value
    when Integer then value.positive? ? value : nil
    when String
      value.match?(/\A[1-9]\d*\z/) ? value.to_i : nil
    end
  end

  private

  def peppol_required?(platform_invoice)
    platform_invoice.customer_vat.present?
  end

  def manual_reconciliation_required?(platform_invoice)
    platform_invoice.octopus_error.to_s.start_with?(MANUAL_RECONCILIATION_CODE)
  end

  def peppol_action_required?(platform_invoice)
    platform_invoice.octopus_error.to_s.start_with?(PEPPOL_ACTION_REQUIRED_CODE)
  end

  def mark_manual_reconciliation!(platform_invoice)
    platform_invoice.update!(
      octopus_status: 'failed',
      octopus_error: "#{MANUAL_RECONCILIATION_CODE}: reconcile the provider document before retrying"
    )
  end

  def raise_manual_reconciliation!(platform_invoice)
    mark_manual_reconciliation!(platform_invoice) unless manual_reconciliation_required?(platform_invoice)
    raise ManualReconciliationRequired, 'Provider reconciliation is required before retrying this invoice'
  end

  def mark_peppol_action_required!(platform_invoice)
    platform_invoice.update!(
      octopus_status: 'failed',
      octopus_error: "#{PEPPOL_ACTION_REQUIRED_CODE}: structured delivery was not confirmed"
    )
  end

  def mark_failed!(platform_invoice, code)
    platform_invoice.update!(octopus_status: 'failed', octopus_error: code)
  end

  def resume_existing_invoice!(platform_invoice, document_key)
    return platform_invoice if platform_invoice.octopus_status == 'peppol_delivered'
    return platform_invoice unless peppol_required?(platform_invoice)

    # A send timeout is deliberately treated as an asynchronous/pending state.
    # Polling is safe; re-sending the document is not.
    if %w[peppol_sending peppol_sent].include?(platform_invoice.octopus_status)
      refresh_peppol_delivery!(platform_invoice, document_key)
      return platform_invoice
    end

    request_peppol_delivery!(platform_invoice, document_key)
    platform_invoice
  end

  def request_peppol_delivery!(platform_invoice, document_key)
    # Fence dispatch before sending: a restart or indeterminate response can
    # only poll this document, not issue another transmission.
    claimed = PlatformInvoice.where(id: platform_invoice.id,
                                    octopus_invoice_key: platform_invoice.octopus_invoice_key,
                                    octopus_status: platform_invoice.octopus_status,
                                    octopus_error: platform_invoice.octopus_error)
                             .where.not(octopus_status: %w[peppol_sending peppol_sent peppol_delivered])
                             .update_all(octopus_status: 'peppol_sending', octopus_error: nil)
    platform_invoice.reload
    unless claimed == 1
      refresh_peppol_delivery!(platform_invoice, document_key)
      return
    end
    response = send_invoice_peppol(document_key)
    entry = self.class.send_entry_for(response, document_key)

    unless entry && entry['success'] == true && entry['sendMethod'].to_s.upcase == 'PEPPOL'
      mark_peppol_action_required!(platform_invoice)
      raise PeppolActionRequired, 'Structured delivery was not accepted by Octopus'
    end

    platform_invoice.update!(octopus_status: 'peppol_sending', octopus_error: nil)
  rescue Timeout::Error
    # Do not send the same document again after an indeterminate request.  Its
    # eventual status can be observed through the report endpoint.
    platform_invoice.update!(octopus_status: 'peppol_sending', octopus_error: nil)
    raise
  rescue PeppolActionRequired
    mark_peppol_action_required!(platform_invoice)
    raise
  end

  def refresh_peppol_delivery!(platform_invoice, document_key = nil)
    key = document_key || self.class.document_key_from_storage(platform_invoice.octopus_invoice_key)
    unless key
      mark_manual_reconciliation!(platform_invoice)
      raise ManualReconciliationRequired, 'Stored Octopus key cannot be matched to a delivery report'
    end

    response = get_delivery_status(key)
    entry = self.class.delivery_entry_for(response, key)
    return nil unless entry

    case entry['deliveryState'].to_s.upcase
    when 'PEPPOL_SEND_OK'
      platform_invoice.update!(octopus_status: 'peppol_delivered', octopus_error: nil)
    when 'PEPPOL_SENDING_IN_PROGRESS', 'NONE'
      platform_invoice.update!(octopus_status: 'peppol_sending')
    when 'PEPPOL_SEND_FAILED', 'ERROR', 'EMAILED', 'PRINTED', 'PRINTED_AND_EMAILED', 'EXPORTED', 'PUBLISHED'
      # E-mail/print/export are valid Octopus delivery states, but none proves
      # the required structured transport for this VAT-bearing invoice.
      mark_peppol_action_required!(platform_invoice)
    end

    entry
  end

  def document_key_for_payload(invoice_data)
    key = {
      'bookyearKey' => invoice_data['bookyearKey'],
      'journal' => invoice_data['journalKey'],
      'documentSequenceNr' => invoice_data['documentSequenceNr']
    }
    self.class.document_key_from_storage(key) || raise(InvoiceError, 'Created invoice did not have a valid document key')
  end

  def document_selection_for(document_key)
    key = self.class.document_key_from_storage(document_key)
    raise InvoiceError, 'Octopus document key is invalid' unless key

    key.merge('toDocumentSequenceNr' => key['documentSequenceNr'])
  end

  def send_request_for(document_key)
    sender = ENV['OCTOPUS_FROM_EMAIL'].to_s.strip
    unless sender.match?(URI::MailTo::EMAIL_REGEXP)
      raise PeppolActionRequired, 'OCTOPUS_FROM_EMAIL must be configured for structured delivery'
    end

    document_selection_for(document_key).merge('fromMailAddress' => sender)
  end

  # --- Token Management ---

  def auth_token_expired?
    @auth_token.nil? || @auth_token_expires_at.nil? || Time.current >= @auth_token_expires_at
  end

  def dossier_token_expired?
    @dossier_token.nil? || @dossier_token_expires_at.nil? || Time.current >= @dossier_token_expires_at
  end

  # --- HTTP Layer ---

  def get(path, params: {})
    request(:get, path, params: params)
  end

  def post(path, body = nil, headers: {}, params: {}, skip_auth: false)
    request(:post, path, body: body, headers: headers, params: params, skip_auth: skip_auth)
  end

  def put(path, body = nil)
    request(:put, path, body: body)
  end

  def request(method, path, body: nil, headers: {}, params: {}, skip_auth: false)
    uri = URI("#{API_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 30

    req = case method
          when :get then Net::HTTP::Get.new(uri)
          when :post then Net::HTTP::Post.new(uri)
          when :put then Net::HTTP::Put.new(uri)
          when :delete then Net::HTTP::Delete.new(uri)
          end

    # Standard headers
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req['Accept-Language'] = 'nl' # Dutch error messages

    # Auth headers
    req['dossierToken'] = @dossier_token if !skip_auth && @dossier_token

    # Custom headers (for auth calls)
    headers.each { |k, v| req[k] = v }

    # Session cookies (required by Octopus!)
    req['Cookie'] = @cookies.map { |k, v| "#{k}=#{v}" }.join('; ') if @cookies.any?

    # Body
    req.body = body.to_json if body

    response = http.request(req)

    # Store session cookies
    if response['Set-Cookie']
      response.get_fields('Set-Cookie')&.each do |cookie_str|
        name, value = cookie_str.split(';').first.split('=', 2)
        @cookies[name.strip] = value&.strip
      end
    end

    # Handle response
    case response.code.to_i
    when 200..299
      return nil if response.body.blank?

      JSON.parse(response.body)
    when 401
      # Token expired - clear cached tokens so next call re-authenticates
      @auth_token = nil
      @dossier_token = nil
      raise AuthenticationError.new(
        parse_error_message(response),
        http_code: 401,
        octopus_code: parse_error_code(response)
      )
    when 403
      raise OctopusError.new(
        parse_error_message(response),
        http_code: 403,
        octopus_code: parse_error_code(response)
      )
    else
      raise OctopusError.new(
        parse_error_message(response),
        http_code: response.code.to_i,
        octopus_code: parse_error_code(response),
        technical_info: parse_technical_info(response)
      )
    end
  end

  def parse_error_message(response)
    body = begin
      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[OctopusApi] Operation failed: #{e.message}")
      {}
    end
    body['description'] || body['errorMessage'] || "HTTP #{response.code}: #{response.message}"
  end

  def parse_error_code(response)
    body = begin
      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[OctopusApi] Operation failed: #{e.message}")
      {}
    end
    body['octopusErrorCode'] || body['errorCode']
  end

  def parse_technical_info(response)
    body = begin
      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[OctopusApi] Operation failed: #{e.message}")
      {}
    end
    body['technicalDescription'] || body['technicalInfo']
  end

  # --- Payload Builders ---

  def build_invoice_payload(platform_invoice:, bookyear:, journal:, vat_code:, relation:)
    next_doc_nr = (journal['lastBookedDocumentNr'] || 0) + 1
    period = find_current_period(bookyear)
    credit_note = platform_invoice.credit_note?
    reference = octopus_document_reference(platform_invoice)
    unit_price = platform_invoice.subtotal_euros
    if credit_note
      validate_credit_note_amounts!(platform_invoice)
      unit_price = unit_price.abs
    end

    payload = {
      'bookyearKey' => bookyear['bookyearKey'],
      'journalKey' => journal['journalKey'],
      'documentSequenceNr' => next_doc_nr,
      'bookyearPeriodeNr' => period,
      'documentDate' => platform_invoice.created_at.strftime('%Y-%m-%d'),
      'expiryDate' => (platform_invoice.created_at + 30.days).strftime('%Y-%m-%d'),
      'currencyCode' => 'EUR',
      'exchangeRate' => 1.0,
      'relationIdentificationServiceData' => relation,
      'comment' => octopus_comment(platform_invoice, reference),
      'reference' => reference,
      'financialDiscount' => 0.0,
      'invoiceLines' => [{
        'vatCodeKey' => vat_code&.dig('code') || 'V21',
        'bookingAccountNr' => vat_code&.dig('defaultSellBookingAccountNr') || 700_000,
        # Octopus infers a credit note from a negative invoice total. Negating
        # count keeps the unit price positive for the generated UBL line.
        'count' => credit_note ? -1.0 : 1.0,
        'description' => invoice_line_description(platform_invoice),
        'unitPrice' => unit_price,
        'unit' => '#',
        'discountPercentage' => 0.0
      }]
    }

    # Add Peppol fields (EN 16931 compliant) – invoicePeriod for subscriptions
    peppol_fields = build_peppol_fields(platform_invoice)
    payload['peppolFields'] = peppol_fields if peppol_fields.present?

    payload
  end

  def build_booking_payload(platform_invoice:, bookyear:, journal:, vat_code:, relation:)
    next_doc_nr = (journal['lastBookedDocumentNr'] || 0) + 1
    period = find_current_period(bookyear)
    credit_note = platform_invoice.credit_note?
    reference = octopus_document_reference(platform_invoice)

    base_amount = platform_invoice.subtotal_euros
    vat_amount = platform_invoice.vat_euros
    document_total = platform_invoice.total_euros
    if credit_note
      validate_credit_note_amounts!(platform_invoice)
      # Octopus's booking API identifies a credit note by its negative header
      # total while requiring the contributing base/VAT line values positive.
      document_total = -document_total.abs
      base_amount = base_amount.abs
      vat_amount = vat_amount.abs
    end

    {
      'bookyearKey' => bookyear['bookyearKey'],
      'journalKey' => journal['journalKey'],
      'documentSequenceNr' => next_doc_nr,
      'relationIdentificationServiceData' => relation,
      'bookyearPeriodeNr' => period,
      'documentDate' => platform_invoice.created_at.strftime('%Y-%m-%d'),
      'expiryDate' => (platform_invoice.created_at + 30.days).strftime('%Y-%m-%d'),
      'comment' => octopus_comment(platform_invoice, reference),
      'reference' => reference,
      'amount' => document_total,
      'currencyCode' => 'EUR',
      'exchangeRate' => 1.0,
      'bookingLines' => [{
        'accountKey' => vat_code&.dig('defaultSellBookingAccountNr') || 700_000,
        'baseAmount' => base_amount,
        'vatAmount' => vat_amount,
        'vatCodeKey' => vat_code&.dig('code') || 'V21',
        'vatRecupPercentage' => 100.0,
        'comment' => invoice_line_description(platform_invoice)
      }]
    }
  end

  def invoice_line_description(platform_invoice)
    case platform_invoice.invoice_type
    when 'subscription'
      'WetWijzer Pro - Maandabonnement'
    when 'credit_purchase'
      'WetWijzer AI Credits'
    when 'credit_note'
      "WetWijzer Credit Note - #{octopus_document_reference(platform_invoice)}"
    else
      "WetWijzer - #{platform_invoice.invoice_type}"
    end
  end

  # --- Reference Data Helpers ---

  def current_bookyear
    years = get_bookyears
    return nil unless years.is_a?(Array) && years.any?

    today = Date.current
    years.find do |y|
      periods = y['periods'] || []
      periods.any? do |p|
        start_date = begin
          Date.parse(p['startDate'])
        rescue StandardError => e
          Rails.logger.warn("[OctopusApi] Operation failed: #{e.message}")
          nil
        end
        end_date = begin
          Date.parse(p['endDate'])
        rescue StandardError => e
          Rails.logger.warn("[OctopusApi] Operation failed: #{e.message}")
          nil
        end
        start_date && end_date && today.between?(start_date, end_date)
      end
    end || years.last
  end

  def find_current_period(bookyear)
    periods = bookyear&.dig('periods') || []
    today = Date.current

    period = periods.find do |p|
      start_date = begin
        Date.parse(p['startDate'])
      rescue StandardError => e
        Rails.logger.warn("[OctopusApi] Operation failed: #{e.message}")
        nil
      end
      end_date = begin
        Date.parse(p['endDate'])
      rescue StandardError => e
        Rails.logger.warn("[OctopusApi] Operation failed: #{e.message}")
        nil
      end
      start_date && end_date && today.between?(start_date, end_date)
    end

    period&.dig('bookyearPeriod') || 1
  end

  def sell_journal(bookyear)
    return nil unless bookyear

    bookyear_id = bookyear.dig('bookyearKey', 'id')
    return nil unless bookyear_id

    journals = get_journals(bookyear_id)
    return nil unless journals.is_a?(Array)

    # Look for a sell journal (type 'V' in Octopus)
    journals.find { |j| j['type']&.to_s&.upcase == 'V' } ||
      journals.find { |j| j['description']&.downcase&.include?('verkoop') } ||
      journals.first
  end

  def sell_vat_code_21
    codes = get_vat_codes
    return nil unless codes.is_a?(Array)

    # Find Belgian 21% sell VAT code
    codes.find { |v| v['type']&.to_s == '2' && (v['basePercentage'].to_f - 21.0).abs < 0.01 } ||
      codes.find { |v| (v['basePercentage'].to_f - 21.0).abs < 0.01 }
  end

  def normalize_vat(vat)
    vat.to_s.gsub(/[\s.]/, '').upcase
  end

  def extract_invoice_key(response)
    return nil unless response.is_a?(Hash)

    response['invoiceKey'] || response.dig('invoiceKey', 'id') || response['id']
  end

  def fallback_to_booking(platform_invoice)
    response = create_booking(platform_invoice)

    platform_invoice.update!(
      octopus_status: 'synced',
      octopus_invoice_key: "booking:#{response&.dig('documentSequenceNr')}",
      octopus_synced_at: Time.current,
      octopus_error: nil
    )

    platform_invoice
  rescue OctopusError => e
    platform_invoice.update!(
      octopus_status: 'failed',
      octopus_error: "Booking fallback also failed: #{e.message}"
    )
    raise
  end

  # --- Peppol Fields (EN 16931) ---

  # Build optional Peppol fields for the invoice payload.
  # Currently adds invoicePeriod for subscription invoices (monthly billing).
  def build_peppol_fields(platform_invoice)
    fields = {}

    # Invoice period – required for subscriptions, useful for EN 16931 compliance
    if platform_invoice.invoice_type == 'subscription'
      invoice_date = platform_invoice.created_at.to_date
      fields['invoicePeriod'] = {
        # Octopus's Peppol OpenAPI models these as StartDate/EndDate value
        # objects, not bare ISO date strings.
        'startDate' => { 'value' => invoice_date.beginning_of_month.strftime('%Y-%m-%d') },
        'endDate' => { 'value' => invoice_date.end_of_month.strftime('%Y-%m-%d') }
      }
    end

    # Peppol requires a buyer reference or purchase-order reference for every
    # routed document, not only B2G. Prefer an explicit reference when the
    # model gains one; otherwise Peppol guidance permits the known ordering
    # contact/name.
    buyer_reference = if platform_invoice.respond_to?(:buyer_reference)
                        platform_invoice.buyer_reference.presence
                      end
    buyer_reference ||= platform_invoice.customer_name.to_s.presence
    fields['buyerReference'] = { 'value' => buyer_reference } if buyer_reference

    if platform_invoice.credit_note?
      original = credit_note_original_invoice!(platform_invoice)
      fields['billingReferences'] = [{
        'invoiceDocumentReference' => {
          'id' => { 'value' => original.invoice_number },
          'issueDate' => { 'value' => original.created_at.to_date.strftime('%Y-%m-%d') }
        }
      }]
    end

    fields.presence
  end

  def octopus_document_reference(platform_invoice)
    return platform_invoice.invoice_number unless platform_invoice.credit_note?

    credit_note_original_invoice!(platform_invoice).invoice_number
  end

  def octopus_comment(platform_invoice, reference)
    return "WetWijzer #{platform_invoice.invoice_number}" unless platform_invoice.credit_note?

    "WetWijzer credit note #{platform_invoice.invoice_number} for #{reference}"
  end

  def credit_note_original_invoice!(platform_invoice)
    original = platform_invoice.original_invoice
    return original if original&.invoice_number.present?

    raise InvoiceError, 'Credit note requires an original invoice reference'
  end

  def validate_credit_note_amounts!(platform_invoice)
    return if platform_invoice.subtotal_euros.positive? &&
              platform_invoice.total_euros.positive? &&
              platform_invoice.vat_euros >= 0

    raise InvoiceError, 'Credit note amounts must be stored as positive values'
  end

  # --- Delivery State Mapping ---

  # Maps Octopus DocumentDeliveryState enum values to our internal octopus_status.
  # Octopus API values: NONE, ERROR, EXPORTED, PRINTED, EMAILED,
  #   PRINTED_AND_EMAILED, PUBLISHED, PEPPOL_SENDING_IN_PROGRESS,
  #   PEPPOL_SEND_OK, PEPPOL_SEND_FAILED
  DELIVERY_STATE_MAP = {
    'NONE' => nil,
    'ERROR' => 'failed',
    'EXPORTED' => 'synced',
    'PRINTED' => 'synced',
    'EMAILED' => 'synced',
    'PRINTED_AND_EMAILED' => 'synced',
    'PUBLISHED' => 'synced',
    'PEPPOL_SENDING_IN_PROGRESS' => 'peppol_sending',
    'PEPPOL_SEND_OK' => 'peppol_delivered',
    'PEPPOL_SEND_FAILED' => 'failed'
  }.freeze

  def self.map_delivery_state(octopus_state)
    DELIVERY_STATE_MAP[octopus_state.to_s.upcase] || octopus_state
  end

  # Used by the scheduled poller and the explicitly requested admin check.
  public :refresh_peppol_delivery!
end
