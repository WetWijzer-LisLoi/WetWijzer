# frozen_string_literal: true

class CreditPurchase < ApplicationRecord
  belongs_to :user

  PACKAGES = {
    'starter' => { price_cents: 500, credits: 50, label: '50 credits' },
    'standard' => { price_cents: 1500, credits: 200, label: '200 credits' },
    'pro' => { price_cents: 3500, credits: 600, label: '600 credits' }
  }.freeze

  STATUSES = %w[pending completed failed refunded].freeze

  validates :package, presence: true, inclusion: { in: PACKAGES.keys }
  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :credits_granted, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :completed, -> { where(status: 'completed') }
  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }

  def self.package_info(package_name)
    PACKAGES[package_name.to_s]
  end

  def complete!
    return if status == 'completed'

    transaction do
      update!(status: 'completed')
      user.add_credits!(credits_granted)
    end
  end

  def fail!
    update!(status: 'failed')
  end

  def refund!
    return unless status == 'completed'

    transaction do
      update!(status: 'refunded')
      user.deduct_credits!(credits_granted)
    end
  end

  def price_euros
    amount_cents / 100.0
  end

  def completed?
    status == 'completed'
  end

  def pending?
    status == 'pending'
  end
end
