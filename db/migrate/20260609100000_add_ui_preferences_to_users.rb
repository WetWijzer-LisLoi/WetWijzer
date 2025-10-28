# frozen_string_literal: true

class AddUiPreferencesToUsers < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:users, :ui_preferences)
      add_column :users, :ui_preferences, :text
    end
  end
end
