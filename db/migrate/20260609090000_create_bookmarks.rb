# frozen_string_literal: true

class CreateBookmarks < ActiveRecord::Migration[8.0]
  def change
    unless table_exists?(:bookmarks)
      create_table :bookmarks do |t|
        t.references :user, null: false, foreign_key: true
        t.string :numac, null: false, limit: 50
        t.string :title, limit: 500
        t.string :url, limit: 1000
        t.string :folder, limit: 100
        t.datetime :bookmarked_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
        t.timestamps
      end

      add_index :bookmarks, [:user_id, :numac], unique: true
      add_index :bookmarks, [:user_id, :folder]
      add_index :bookmarks, [:user_id, :bookmarked_at]
    end
  end
end
