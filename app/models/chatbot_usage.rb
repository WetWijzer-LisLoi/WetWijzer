# frozen_string_literal: true

class ChatbotUsage < ApplicationRecord
  belongs_to :user, optional: true

  validates :usage_date, presence: true
  validates :query_count, numericality: { greater_than_or_equal_to: 0 }

  scope :for_date, ->(date) { where(usage_date: date) }
  scope :for_user, ->(user) { where(user: user) }
  scope :for_session, ->(session_id) { where(session_id: session_id) }
  scope :this_month, -> { where(usage_date: Date.current.beginning_of_month..Date.current.end_of_month) }

  def self.track_anonymous(ip_address, user_agent)
    session_id = Digest::SHA256.hexdigest("#{ip_address}:#{Date.current}")
    
    usage = find_or_create_by!(session_id: session_id, usage_date: Date.current) do |u|
      u.ip_hash = Digest::SHA256.hexdigest(ip_address)
      u.user_agent_hash = Digest::SHA256.hexdigest(user_agent.to_s)
    end
    
    usage.increment!(:query_count)
    usage
  end

  def self.anonymous_count_today(ip_address)
    session_id = Digest::SHA256.hexdigest("#{ip_address}:#{Date.current}")
    find_by(session_id: session_id, usage_date: Date.current)&.query_count || 0
  end

  def self.within_anonymous_limit?(ip_address, limit: 5)
    anonymous_count_today(ip_address) < limit
  end
end
