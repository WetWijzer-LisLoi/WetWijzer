# frozen_string_literal: true

class AddCancellationReasonToSubscriptions < ActiveRecord::Migration[8.0]
  def change
    add_column :subscriptions, :cancellation_reason, :text
    add_column :subscriptions, :canceled_at, :datetime
    add_column :users, :deletion_final_warning_sent_at, :datetime
  end
end
