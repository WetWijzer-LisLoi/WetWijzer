# frozen_string_literal: true

class SavedAnswer < ApplicationRecord
  belongs_to :user

  validates :question, presence: true, length: { maximum: 1000 }
  validates :answer, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :by_category, ->(cat) { where(category: cat) if cat.present? }

  def self.categories_for_user(user)
    where(user: user).distinct.pluck(:category).compact
  end
end
