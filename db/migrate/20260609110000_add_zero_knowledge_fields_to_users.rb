# frozen_string_literal: true

class AddZeroKnowledgeFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:users, :encrypted_master_key)
      add_column :users, :encrypted_master_key, :text     # Client-wrapped master key blob (base64)
    end
    unless column_exists?(:users, :key_derivation_salt)
      add_column :users, :key_derivation_salt, :string     # Unique PBKDF2 salt per user (base64)
    end
  end
end
