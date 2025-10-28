# frozen_string_literal: true

# PEPPOL E-Invoice Service for Belgian B2B compliance (mandatory since Jan 1, 2026)
# Integrates with Storecove API as PEPPOL Access Point
# Reference: https://www.storecove.com/docs/
class PeppolInvoiceService
  STORECOVE_API_URL = 'https://api.storecove.com/api/v2'
  
  class PeppolError < StandardError; end

  def initialize
    @api_key = ENV.fetch('STORECOVE_API_KEY', nil)
    @legal_entity_id = ENV.fetch('STORECOVE_LEGAL_ENTITY_ID', nil)
  end

  # Send invoice via PEPPOL network
  # Called from Stripe webhook when invoice.paid event occurs
  def send_invoice(stripe_invoice, user)
    return unless should_send_peppol?(user)
    return unless @api_key.present?

    invoice_data = build_peppol_invoice(stripe_invoice, user)
    
    response = post_to_storecove('/document_submissions', {
      legal_entity_id: @legal_entity_id,
      document: invoice_data
    })

    if response[:guid]
      Rails.logger.info("PEPPOL invoice sent: #{response[:guid]} for Stripe invoice #{stripe_invoice.id}")
      store_peppol_reference(stripe_invoice.id, response[:guid], user)
      response
    else
      Rails.logger.error("PEPPOL invoice failed: #{response[:errors]}")
      raise PeppolError, response[:errors]&.join(', ') || 'Unknown PEPPOL error'
    end
  end

  # Check if customer can receive PEPPOL invoices
  def lookup_recipient(vat_number)
    return nil unless @api_key.present?
    
    # Clean VAT number (remove spaces, ensure BE prefix)
    clean_vat = vat_number.to_s.gsub(/\s/, '').upcase
    clean_vat = "BE#{clean_vat}" unless clean_vat.start_with?('BE')
    
    response = get_from_storecove("/discovery/receives", {
      identifier: clean_vat,
      scheme: 'BE:EN'  # Belgian Enterprise Number scheme
    })
    
    response[:receives]&.any? { |r| r[:document_type] == 'invoice' }
  end

  private

  def should_send_peppol?(user)
    # Only send PEPPOL invoices for Belgian B2B customers with VAT number
    subscription = user.subscription
    return false unless subscription
    
    # Check if customer has Belgian VAT number
    vat_number = subscription.vat_number
    return false unless vat_number.present?
    return false unless vat_number.upcase.start_with?('BE')
    
    true
  end

  def build_peppol_invoice(stripe_invoice, user)
    subscription = user.subscription
    
    {
      document_type: 'invoice',
      invoice: {
        invoice_number: stripe_invoice.number || stripe_invoice.id,
        issue_date: Time.at(stripe_invoice.created).strftime('%Y-%m-%d'),
        due_date: stripe_invoice.due_date ? Time.at(stripe_invoice.due_date).strftime('%Y-%m-%d') : nil,
        document_currency_code: stripe_invoice.currency.upcase,
        
        # Seller (WetWijzer)
        accounting_supplier_party: seller_party,
        
        # Buyer
        accounting_customer_party: buyer_party(user, subscription),
        
        # Tax totals
        tax_total: build_tax_total(stripe_invoice),
        
        # Invoice totals
        legal_monetary_total: {
          tax_exclusive_amount: cents_to_euros(stripe_invoice.subtotal),
          tax_inclusive_amount: cents_to_euros(stripe_invoice.total),
          payable_amount: cents_to_euros(stripe_invoice.amount_due)
        },
        
        # Line items
        invoice_lines: build_invoice_lines(stripe_invoice),
        
        # Payment means
        payment_means: {
          payment_means_code: '58', # SEPA credit transfer
          payment_id: stripe_invoice.id
        }
      }
    }
  end

  def seller_party
    {
      party: {
        endpoint_id: ENV.fetch('PEPPOL_SELLER_ID', 'BE0123456789'),
        endpoint_scheme_id: 'BE:EN',
        party_identification: {
          id: ENV.fetch('COMPANY_VAT_NUMBER', 'BE0123456789'),
          scheme_id: 'BE:EN'
        },
        party_name: 'WetWijzer',
        postal_address: {
          street_name: ENV.fetch('COMPANY_STREET', 'Wetstraat 1'),
          city_name: ENV.fetch('COMPANY_CITY', 'Brussel'),
          postal_zone: ENV.fetch('COMPANY_POSTAL', '1000'),
          country: { identification_code: 'BE' }
        },
        party_tax_scheme: {
          company_id: ENV.fetch('COMPANY_VAT_NUMBER', 'BE0123456789'),
          tax_scheme_id: 'VAT'
        },
        party_legal_entity: {
          registration_name: 'WetWijzer',
          company_id: ENV.fetch('COMPANY_ENTERPRISE_NUMBER', '0123456789'),
          company_id_scheme_id: 'BE:EN'
        },
        contact: {
          name: 'Billing',
          email: ENV.fetch('BILLING_EMAIL', 'billing@wetwijzer.be')
        }
      }
    }
  end

  def buyer_party(user, subscription)
    {
      party: {
        endpoint_id: subscription.vat_number&.gsub(/\s/, '')&.upcase,
        endpoint_scheme_id: 'BE:EN',
        party_identification: {
          id: subscription.vat_number&.gsub(/\s/, '')&.upcase,
          scheme_id: 'BE:EN'
        },
        party_name: subscription.company_name || user.name || user.email,
        postal_address: {
          street_name: subscription.billing_address_line1 || '',
          city_name: subscription.billing_city || '',
          postal_zone: subscription.billing_postal_code || '',
          country: { identification_code: subscription.billing_country || 'BE' }
        },
        party_tax_scheme: {
          company_id: subscription.vat_number&.gsub(/\s/, '')&.upcase,
          tax_scheme_id: 'VAT'
        },
        party_legal_entity: {
          registration_name: subscription.company_name || user.name || user.email
        },
        contact: {
          name: user.name || 'Billing',
          email: user.email
        }
      }
    }
  end

  def build_tax_total(stripe_invoice)
    tax_amount = stripe_invoice.tax || 0
    subtotal = stripe_invoice.subtotal || 0
    
    # Belgian VAT rate (21% for digital services)
    vat_rate = 21.0
    
    {
      tax_amount: cents_to_euros(tax_amount),
      tax_subtotal: [{
        taxable_amount: cents_to_euros(subtotal),
        tax_amount: cents_to_euros(tax_amount),
        tax_category: {
          id: 'S',  # Standard rate
          percent: vat_rate,
          tax_scheme_id: 'VAT'
        }
      }]
    }
  end

  def build_invoice_lines(stripe_invoice)
    stripe_invoice.lines.data.map.with_index do |line, index|
      {
        id: (index + 1).to_s,
        invoiced_quantity: line.quantity || 1,
        invoiced_quantity_unit_code: 'C62', # Unit
        line_extension_amount: cents_to_euros(line.amount),
        item: {
          description: line.description || 'Subscription',
          name: line.description&.truncate(50) || 'WetWijzer Subscription',
          sellers_item_identification: line.price&.id || 'SUBSCRIPTION',
          classified_tax_category: {
            id: 'S',
            percent: 21.0,
            tax_scheme_id: 'VAT'
          }
        },
        price: {
          price_amount: cents_to_euros(line.unit_amount_excluding_tax || line.amount),
          base_quantity: 1
        }
      }
    end
  end

  def cents_to_euros(cents)
    (cents.to_f / 100).round(2)
  end

  def store_peppol_reference(stripe_invoice_id, peppol_guid, user)
    # Store reference for audit trail
    AccountActivity.log(user, 'peppol_invoice_sent', nil, {
      stripe_invoice_id: stripe_invoice_id,
      peppol_guid: peppol_guid
    })
  end

  def post_to_storecove(endpoint, body)
    uri = URI("#{STORECOVE_API_URL}#{endpoint}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{@api_key}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json
    
    response = http.request(request)
    JSON.parse(response.body, symbolize_names: true)
  rescue StandardError => e
    Rails.logger.error("Storecove API error: #{e.message}")
    { errors: [e.message] }
  end

  def get_from_storecove(endpoint, params = {})
    uri = URI("#{STORECOVE_API_URL}#{endpoint}")
    uri.query = URI.encode_www_form(params) if params.any?
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@api_key}"
    
    response = http.request(request)
    JSON.parse(response.body, symbolize_names: true)
  rescue StandardError => e
    Rails.logger.error("Storecove API error: #{e.message}")
    { errors: [e.message] }
  end
end
