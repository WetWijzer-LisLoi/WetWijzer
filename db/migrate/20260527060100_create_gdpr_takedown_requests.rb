# frozen_string_literal: true

# GDPR Art. 17: Takedown request tracking for jurisprudence personal data.
# Data subjects (litigants, lawyers) can request erasure of personal data
# found in pseudonymized court decisions.
class CreateGdprTakedownRequests < ActiveRecord::Migration[7.0]
  def change
    create_table :gdpr_takedown_requests do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :ecli, null: false
      t.text :description, null: false
      t.string :status, null: false, default: 'pending' # pending, in_review, resolved, rejected
      t.datetime :resolved_at
      t.text :resolution_notes
      t.string :ip_hash, limit: 64

      t.timestamps
    end

    add_index :gdpr_takedown_requests, :ecli
    add_index :gdpr_takedown_requests, :status
    add_index :gdpr_takedown_requests, :created_at
  end
end
