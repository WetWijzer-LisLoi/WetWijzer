# frozen_string_literal: true

# Octopus File Import API client.
# Pushes UBL XML files directly into Octopus DMS (Document Management System)
# where they land in the Document Import Viewer for processing.
#
# This is the SIMPLEST integration path - no Invoice Module required,
# no relation setup, no bookyear configuration. Just push files.
#
# Three endpoints available:
#   1. /dossiers/{dossierId}/files/imports       - needs auth + checksum
#   2. /dossiers/files/imports/stream            - needs unique mailbox address
#   3. /dossiers/{dossierId}/files/imports/withtoken - needs dossier token
#
# This service uses endpoint 1 (auth + checksum) as the primary path,
# with endpoint 3 (dossier token) as fallback.
#
# Environment variables:
#   OCTOPUS_FILE_IMPORT_API_URL  - default: https://service.inaras.be/octopus-file-import-api/v1
#   OCTOPUS_MAILBOX_CHECKSUM     - the dossier's mailbox checksum (found in Octopus DMS settings)
#   (Also uses OCTOPUS_SOFTWARE_HOUSE_ID, USERNAME, PASSWORD, DOSSIER_ID from OctopusApiService)
class OctopusFileImportService
  API_URL = ENV.fetch('OCTOPUS_FILE_IMPORT_API_URL', 'https://service.inaras.be/octopus-file-import-api/v1')
  TOKEN_LIFETIME = 9.minutes

  class FileImportError < StandardError; end

  def initialize
    @software_house_id = ENV.fetch('OCTOPUS_SOFTWARE_HOUSE_ID', nil)
    @username = ENV.fetch('OCTOPUS_USERNAME', nil)
    @password = ENV.fetch('OCTOPUS_PASSWORD', nil)
    @dossier_id = ENV.fetch('OCTOPUS_DOSSIER_ID', nil)&.to_i
    @checksum = ENV.fetch('OCTOPUS_MAILBOX_CHECKSUM', nil)&.to_i

    @auth_token = nil
    @auth_token_expires_at = nil
    @dossier_token = nil
    @dossier_token_expires_at = nil
    @cookies = {}
  end

  def self.enabled?
    ENV.fetch('OCTOPUS_ENABLED', 'false') == 'true' &&
      ENV['OCTOPUS_SOFTWARE_HOUSE_ID'].present? &&
      ENV['OCTOPUS_USERNAME'].present?
  end

  # --- Authentication (File Import API has its own auth endpoints) ---

  def authenticate!
    Rails.logger.info('[OctopusFileImport] Authenticating...')

    response = post_raw('/authentication', {
                          username: @username,
                          password: @password
                        }, headers: { 'softwareHouseUuid' => @software_house_id })

    @auth_token = response['token']
    @auth_token_expires_at = Time.current + TOKEN_LIFETIME

    Rails.logger.info('[OctopusFileImport] Authentication successful')
    @auth_token
  end

  def connect_dossier!
    Rails.logger.info("[OctopusFileImport] Connecting to dossier #{@dossier_id}...")

    response = post_raw('/authentication/connect', nil,
                        headers: {
                          'authenticationToken' => @auth_token,
                          'dossierId' => @dossier_id.to_s
                        })

    @dossier_token = response['dossiertoken'] || response['dossierToken'] || response['token']
    @dossier_token_expires_at = Time.current + TOKEN_LIFETIME

    Rails.logger.info("[OctopusFileImport] Connected to dossier #{@dossier_id}")
    @dossier_token
  end

  def ensure_connected!
    authenticate! if @auth_token.nil? || (@auth_token_expires_at && Time.current >= @auth_token_expires_at)
    connect_dossier! if @dossier_token.nil? || (@dossier_token_expires_at && Time.current >= @dossier_token_expires_at)
  end

  # --- File Import Operations ---

  # Push a single UBL XML file to Octopus DMS
  def import_file(file_path, subfolder: 'WetWijzer Facturen')
    raise FileImportError, "File not found: #{file_path}" unless File.exist?(file_path)

    file_name = File.basename(file_path)
    file_data = File.binread(file_path)

    import_file_data(file_name: file_name, file_data: file_data, subfolder: subfolder)
  end

  # Push file data (binary) to Octopus DMS
  def import_file_data(file_name:, file_data:, subfolder: nil)
    ensure_connected!

    attachment = {
      'fileName' => file_name,
      'fileData' => Base64.strict_encode64(file_data)
    }

    # Use endpoint with dossier token
    uri = URI("#{API_URL}/dossiers/#{@dossier_id}/files/imports/withtoken")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 60 # file uploads can be slow

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['dossierToken'] = @dossier_token

    # Add subfolder as query param
    if subfolder.present?
      uri.query = URI.encode_www_form('subfolder' => subfolder)
      request = Net::HTTP::Post.new(uri)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      request['dossierToken'] = @dossier_token
    end

    # Session cookies
    request['Cookie'] = @cookies.map { |k, v| "#{k}=#{v}" }.join('; ') if @cookies.any?

    request.body = attachment.to_json

    response = http.request(request)

    # Store cookies
    if response['Set-Cookie']
      response.get_fields('Set-Cookie')&.each do |cookie_str|
        name, value = cookie_str.split(';').first.split('=', 2)
        @cookies[name.strip] = value&.strip
      end
    end

    case response.code.to_i
    when 200..299
      Rails.logger.info("[OctopusFileImport] Uploaded #{file_name} to DMS")
      true
    when 401
      @auth_token = nil
      @dossier_token = nil
      raise FileImportError, "Authentication expired: #{response.body}"
    else
      body = begin
        JSON.parse(response.body)
      rescue StandardError => e
        Rails.logger.warn("[OctopusFileImport] Operation failed: #{e.message}")
        {}
      end
      msg = body['description'] || body['errorMessage'] || "HTTP #{response.code}"
      raise FileImportError, msg
    end
  end

  # Push a PlatformInvoice's UBL XML to Octopus DMS
  def import_invoice_xml(platform_invoice, subfolder: 'WetWijzer Facturen')
    raise FileImportError, "No UBL XML for invoice #{platform_invoice.invoice_number}" unless platform_invoice.xml_exists?

    import_file(platform_invoice.safe_xml_path, subfolder: subfolder)
  end

  # Push a PlatformInvoice's PDF to Octopus DMS
  def import_invoice_pdf(platform_invoice, subfolder: 'WetWijzer Facturen')
    raise FileImportError, "No PDF for invoice #{platform_invoice.invoice_number}" unless platform_invoice.pdf_exists?

    import_file(platform_invoice.safe_pdf_path, subfolder: subfolder)
  end

  # Push both XML + PDF for an invoice
  def import_invoice_documents(platform_invoice, subfolder: 'WetWijzer Facturen')
    results = { xml: false, pdf: false }

    if platform_invoice.xml_exists?
      import_invoice_xml(platform_invoice, subfolder: subfolder)
      results[:xml] = true
    end

    if platform_invoice.pdf_exists?
      import_invoice_pdf(platform_invoice, subfolder: subfolder)
      results[:pdf] = true
    end

    results
  end

  private

  def post_raw(path, body = nil, headers: {})
    uri = URI("#{API_URL}#{path}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'

    headers.each { |k, v| request[k] = v }

    request['Cookie'] = @cookies.map { |k, v| "#{k}=#{v}" }.join('; ') if @cookies.any?

    request.body = body.to_json if body

    response = http.request(request)

    # Store cookies
    if response['Set-Cookie']
      response.get_fields('Set-Cookie')&.each do |cookie_str|
        name, value = cookie_str.split(';').first.split('=', 2)
        @cookies[name.strip] = value&.strip
      end
    end

    case response.code.to_i
    when 200..299
      return {} if response.body.blank?

      JSON.parse(response.body)
    else
      body_parsed = begin
        JSON.parse(response.body)
      rescue StandardError => e
        Rails.logger.warn("[OctopusFileImport] Operation failed: #{e.message}")
        {}
      end
      msg = body_parsed['description'] || body_parsed['errorMessage'] || "HTTP #{response.code}"
      raise FileImportError, msg
    end
  end
end
