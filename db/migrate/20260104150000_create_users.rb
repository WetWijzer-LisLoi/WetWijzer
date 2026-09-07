# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      # Core fields
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :name
      t.string :locale, limit: 2, default: 'nl'

      # Email confirmation
      t.string :confirmation_token
      t.datetime :confirmed_at
      t.datetime :confirmation_sent_at

      # Password reset
      t.string :reset_password_token
      t.datetime :reset_password_sent_at

      # Session management
      t.string :session_token
      t.datetime :last_sign_in_at
      t.string :last_sign_in_ip

      # Account status
      t.boolean :active, default: true, null: false
      t.boolean :admin, default: false, null: false

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :confirmation_token, unique: true
    add_index :users, :reset_password_token, unique: true
    add_index :users, :session_token, unique: true
  end
end
