# frozen_string_literal: true

class CreateSearchAlerts < ActiveRecord::Migration[7.1]
  def change
    create_table :search_alerts do |t|
      t.string :email, null: false
      t.string :query, null: false
      t.json :filters, default: {}
      t.string :frequency, default: 'daily' # daily, weekly
      t.string :unsubscribe_token, null: false
      t.datetime :last_notified_at
      t.datetime :confirmed_at
      t.string :confirmation_token
      t.integer :notification_count, default: 0
      t.boolean :active, default: true

      t.timestamps
    end

    add_index :search_alerts, :email
    add_index :search_alerts, :unsubscribe_token, unique: true
    add_index :search_alerts, :confirmation_token, unique: true
    add_index :search_alerts, [:email, :query], unique: true
    add_index :search_alerts, :active
  end
end
