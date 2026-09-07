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

    response = post("/dossiers/#{@dossier_id}/invoices", invoice_data)

    Rails.logger.info("[Octopus] Invoice created for #{platform_invoice.invoice_number}")
    response
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

  # Send invoice via PEPPOL (requires Invoice Module)
  def send_invoice_peppol(invoice_keys)
    ensure_connected!

    response = post("/dossiers/#{@dossier_id}/invoices/send", {
                      'invoiceKeys' => Array(invoice_keys)
                    })

    Rails.logger.info("[Octopus] PEPPOL send initiated for #{invoice_keys}")
    response
  end

  # Check PEPPOL delivery status
  def get_delivery_status(invoice_keys)
    ensure_connected!

    post("/dossiers/#{@dossier_id}/invoices/send/report/deliverystate", {
           'invoiceKeys' => Array(invoice_keys)
         })
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

  # Main entry point: sync a PlatformInvoice to Octopus
  # Tries invoice creation first, falls back to booking if Invoice Module unavailable
  def sync_invoice(platform_invoice)
    platform_invoice.update_columns(octopus_status: 'pending', octopus_error: nil)

    begin
      ensure_connected!

      # Try creating as invoice (enables PEPPOL)
      response = create_invoice(platform_invoice)
      invoice_key = extract_invoice_key(response)

      platform_invoice.update!(
        octopus_status: 'synced',
        octopus_invoice_key: invoice_key,
        octopus_synced_at: Time.current,
        octopus_error: nil
      )

      # Optionally send via PEPPOL if B2B with VAT
      if platform_invoice.customer_vat.present? && invoice_key
        begin
          send_invoice_peppol(invoice_key)
          platform_invoice.update!(octopus_status: 'peppol_sent')
        rescue OctopusError => e
          # PEPPOL send failed, but invoice is synced - not critical
          Rails.logger.warn("[Octopus] PEPPOL send failed for #{platform_invoice.invoice_number}: #{e.message}")
          platform_invoice.update!(octopus_error: "Synced but PEPPOL failed: #{e.message}")
        end
      end

      platform_invoice
    rescue OctopusError => e
      if e.message.include?('module') || e.http_code == 403
        # Invoice Module not active - fall back to booking
        Rails.logger.info('[Octopus] Invoice Module not available, falling back to booking')
        fallback_to_booking(platform_invoice)
      else
        platform_invoice.update!(
          octopus_status: 'failed',
          octopus_error: "#{e.octopus_code}: #{e.message}"
        )
        raise
      end
    end
  end

  private

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
end
