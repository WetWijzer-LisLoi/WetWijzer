# frozen_string_literal: true

class AddCreditsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :credits, :integer, default: 0, null: false
    add_column :users, :credits_refilled_at, :datetime
  end
end
