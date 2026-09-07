# frozen_string_literal: true

class AddCreditCostsToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :subscriptions, :monthly_credit_refill, :integer, default: 0
    add_column :subscriptions, :last_refill_at, :datetime
  end
end
