# frozen_string_literal: true

class AddConversationStorageConsentToUsers < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:users, :conversation_storage_consent)
      add_column :users, :conversation_storage_consent, :boolean, default: false, null: false
    end
    unless column_exists?(:users, :conversation_storage_consented_at)
      add_column :users, :conversation_storage_consented_at, :datetime
    end
  end
end
