# frozen_string_literal: true

class AddAccountLockoutAndActivityTracking < ActiveRecord::Migration[7.1]
  def change
    # Account lockout
    add_column :users, :failed_attempts, :integer, default: 0, null: false
    add_column :users, :locked_until, :datetime
    
    # 2FA
    add_column :users, :otp_secret, :string
    add_column :users, :otp_enabled, :boolean, default: false, null: false
    add_column :users, :otp_backup_codes, :text
    
    # Session management
    add_column :users, :last_activity_at, :datetime
    
    # Activity log
    create_table :account_activities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :action, null: false
      t.string :ip_address
      t.string :user_agent
      t.json :metadata
      t.timestamps
    end
    
    add_index :account_activities, [:user_id, :created_at]
  end
end
