# frozen_string_literal: true

# GDPR Art. 17: Tracks takedown requests from data subjects who find
# their personal data in pseudonymized court decisions.
# Status flow: pending → in_review → resolved/rejected
class GdprTakedownRequest < ApplicationRecord
  VALID_STATUSES = %w[pending in_review resolved rejected].freeze

  validates :name, presence: true, length: { maximum: 200 }
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :ecli, presence: true, length: { maximum: 100 }
  validates :description, presence: true, length: { maximum: 5000 }
  validates :status, inclusion: { in: VALID_STATUSES }

  # Encrypt PII at rest (GDPR Art. 32 — security of processing)
  encrypts :name
  encrypts :email, deterministic: true # deterministic: allows lookup by email
  encrypts :description

  scope :pending, -> { where(status: 'pending') }
  scope :unresolved, -> { where(status: %w[pending in_review]) }

  def resolve!(notes: nil)
    update!(status: 'resolved', resolved_at: Time.current, resolution_notes: notes)
  end

  def reject!(notes: nil)
    update!(status: 'rejected', resolved_at: Time.current, resolution_notes: notes)
  end

  def resolved?
    status == 'resolved'
  end

  def pending?
    status == 'pending'
  end
end
