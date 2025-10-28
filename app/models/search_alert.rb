# frozen_string_literal: true

# SearchAlert model for email notifications when new laws match a saved search
#
# Users can subscribe to search queries without needing an account.
# When new laws matching the query are published, they receive email notifications.
#
# @example Creating a search alert
#   SearchAlert.create!(
#     email: 'user@example.com',
#     query: 'arbeidsrecht',
#     filters: { law: '1', decree: '1' },
#     frequency: 'daily'
#   )
class SearchAlert < ApplicationRecord
  # Validations
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :query, presence: true, length: { minimum: 2, maximum: 500 }
  validates :frequency, inclusion: { in: %w[daily weekly] }
  validates :unsubscribe_token, presence: true, uniqueness: true
  validates :email, uniqueness: { scope: :query, message: :already_subscribed }

  # Rate limiting: max 10 alerts per email
  validate :max_alerts_per_email, on: :create

  # Callbacks
  before_validation :generate_tokens, on: :create

  # Scopes
  scope :active, -> { where(active: true) }
  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :daily, -> { where(frequency: 'daily') }
  scope :weekly, -> { where(frequency: 'weekly') }
  scope :due_for_notification, ->(frequency) {
    confirmed.active.where(frequency: frequency)
             .where('last_notified_at IS NULL OR last_notified_at < ?', notification_threshold(frequency))
  }

  # Class methods
  class << self
    def notification_threshold(frequency)
      case frequency
      when 'daily' then 23.hours.ago
      when 'weekly' then 6.days.ago
      else 23.hours.ago
      end
    end

    # Find new laws matching a search alert since last notification
    # @param alert [SearchAlert] The alert to check
    # @return [ActiveRecord::Relation] New matching laws
    def find_new_matches(alert)
      since = alert.last_notified_at || alert.created_at
      
      # Build search params from stored filters
      search_params = alert.filters.merge('title' => alert.query)
      
      # Use LawSearchService to find matches
      LawSearchService.search(search_params)
                      .where('publication_date > ?', since.to_date)
                      .order(publication_date: :desc)
                      .limit(50)
    end
  end

  # Instance methods
  
  def confirm!
    update!(confirmed_at: Time.current, confirmation_token: nil)
  end

  def confirmed?
    confirmed_at.present?
  end

  def unsubscribe!
    update!(active: false)
  end

  def mark_notified!(count = 0)
    update!(
      last_notified_at: Time.current,
      notification_count: notification_count + count
    )
  end

  private

  def generate_tokens
    self.unsubscribe_token ||= SecureRandom.urlsafe_base64(32)
    self.confirmation_token ||= SecureRandom.urlsafe_base64(32) unless confirmed_at
  end

  def max_alerts_per_email
    return unless email.present?
    
    existing_count = SearchAlert.where(email: email).active.count
    if existing_count >= 10
      errors.add(:base, :max_alerts_reached)
    end
  end
end
