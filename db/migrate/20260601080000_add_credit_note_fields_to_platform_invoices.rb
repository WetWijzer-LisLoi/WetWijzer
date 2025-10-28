# frozen_string_literal: true

class AddCreditNoteFieldsToPlatformInvoices < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:platform_invoices, :original_invoice_id)
      add_column :platform_invoices, :original_invoice_id, :bigint, null: true
    end
    unless column_exists?(:platform_invoices, :refund_reason)
      add_column :platform_invoices, :refund_reason, :string, null: true
    end
    unless index_exists?(:platform_invoices, :original_invoice_id)
      add_index :platform_invoices, :original_invoice_id
    end
    unless foreign_key_exists?(:platform_invoices, :platform_invoices, column: :original_invoice_id)
      add_foreign_key :platform_invoices, :platform_invoices, column: :original_invoice_id
    end
  end
end
