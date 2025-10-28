# frozen_string_literal: true

class InvoicesController < ApplicationController
  before_action :require_authentication

  def index
    @invoices = PlatformInvoice.for_user(current_user).limit(50)
  end

  def download
    invoice = PlatformInvoice.find_by!(id: params[:id], user: current_user)

    if invoice.pdf_exists?
      send_file invoice.pdf_path,
                filename: "factuur_#{invoice.invoice_number}.pdf",
                type: 'application/pdf',
                disposition: 'attachment'
    else
      redirect_to invoices_path, alert: 'Factuur PDF niet gevonden.'
    end
  end

  def download_xml
    invoice = PlatformInvoice.find_by!(id: params[:id], user: current_user)

    if invoice.xml_exists?
      send_file invoice.xml_path,
                filename: "factuur_#{invoice.invoice_number}.xml",
                type: 'application/xml',
                disposition: 'attachment'
    else
      redirect_to invoices_path, alert: 'UBL XML niet gevonden.'
    end
  end
end
