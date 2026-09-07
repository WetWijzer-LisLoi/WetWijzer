# frozen_string_literal: true

class CreateSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :subscriptions do |t|
      t.references :user, null: false, foreign_key: true

      # Tier: 'free', 'pro'
      t.string :tier, null: false, default: 'free'

      # Stripe integration
      t.string :stripe_customer_id
      t.string :stripe_subscription_id
      t.string :stripe_price_id

      # Subscription status
      t.string :status, null: false, default: 'active' # active, canceled
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.datetime :canceled_at

      # Billing info (PEPPOL e-invoicing)
      t.string :vat_number

      t.timestamps
    end

    add_index :subscriptions, :stripe_customer_id
    add_index :subscriptions, :stripe_subscription_id, unique: true
    add_index :subscriptions, :status
    add_index :subscriptions, :tier
  end
end
