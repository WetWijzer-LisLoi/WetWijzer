# frozen_string_literal: true

class AddUnverifiedWarningFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :unverified_warning_sent_at, :datetime, null: true
    add_column :users, :unverified_final_warning_sent_at, :datetime, null: true
  end
end
