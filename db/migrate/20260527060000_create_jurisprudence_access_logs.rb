# frozen_string_literal: true

# GDPR: Access logging for jurisprudence (case law) views.
# Tracks which Pro user accessed which case for accountability and abuse detection.
# Retention: 1 year (records older than 1 year should be purged via scheduled job).
class CreateJurisprudenceAccessLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :jurisprudence_access_logs do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.string :ecli, null: false
      t.string :ip_hash, limit: 64
      t.datetime :accessed_at, null: false

      t.index :ecli
      t.index :accessed_at
    end
  end
end
