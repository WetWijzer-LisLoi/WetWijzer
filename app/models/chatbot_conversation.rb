# frozen_string_literal: true

class ChatbotConversation < ApplicationRecord
  # Use separate SQLite database for chatbot data
  # Keeps main laws.db clean, easier SaaS migration later
  establish_connection(
    adapter: 'sqlite3',
    database: Rails.root.join('storage', 'chatbot.sqlite3').to_s,
    pool: 5,
    timeout: 5000
  )

  # Override readonly - Rails marks models with establish_connection as readonly by default
  def readonly?
    false
  end

  EXPIRY_DURATION = 24.hours
  MAX_MESSAGES = 20

  # Create table if not exists (self-initializing)
  def self.ensure_table_exists
    return if connection.table_exists?(:chatbot_conversations)
    
    connection.create_table :chatbot_conversations do |t|
      t.string :token, null: false, index: { unique: true }
      t.string :user_id
      t.string :language, default: 'nl'
      t.text :messages
      t.text :context_numacs
      t.string :last_question
      t.integer :message_count, default: 0
      t.datetime :expires_at
      t.timestamps
    end
    connection.add_index :chatbot_conversations, :user_id
    connection.add_index :chatbot_conversations, :expires_at
  end

  before_validation :generate_token, on: :create
  before_create :set_expiry

  validates :token, presence: true, uniqueness: true
  validates :language, inclusion: { in: %w[nl fr] }

  def messages_array
    JSON.parse(messages || '[]')
  rescue JSON::ParserError
    []
  end

  def messages_array=(array)
    self.messages = array.to_json
  end

  def context_numacs_array
    JSON.parse(context_numacs || '[]')
  rescue JSON::ParserError
    []
  end

  def context_numacs_array=(array)
    self.context_numacs = array.to_json
  end

  def add_message(role:, content:, numacs: [])
    msgs = messages_array
    msgs << { role: role, content: content, timestamp: Time.current.iso8601 }
    
    # Keep only last MAX_MESSAGES
    msgs = msgs.last(MAX_MESSAGES) if msgs.length > MAX_MESSAGES
    
    self.messages_array = msgs
    self.message_count = msgs.length
    self.last_question = content if role == 'user'
    
    # Update context NUMACs (keep unique, most recent first)
    if numacs.present?
      existing = context_numacs_array
      self.context_numacs_array = (numacs + existing).uniq.first(10)
    end
    
    save!
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def extend_expiry!
    update!(expires_at: EXPIRY_DURATION.from_now)
  end

  def conversation_context
    # Build context string from recent messages for LLM
    msgs = messages_array.last(6) # Last 3 exchanges
    return nil if msgs.empty?

    msgs.map do |m|
      role_label = m['role'] == 'user' ? 'Gebruiker' : 'Assistent'
      "#{role_label}: #{m['content']}"
    end.join("\n\n")
  end

  # Cleanup expired conversations
  def self.cleanup_expired
    where('expires_at < ?', Time.current).delete_all
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_expiry
    self.expires_at ||= EXPIRY_DURATION.from_now
  end
end
