# frozen_string_literal: true

class CreateLegislationArchive < ActiveRecord::Migration[7.0]
  def change
    create_table :legislation_archive do |t|
      t.string :numac, limit: 10, null: false
      t.integer :law_type_id, null: false
      t.integer :year, null: false
      t.string :date, limit: 10, null: false
      t.text :title, null: false
      t.string :justel, limit: 255, null: false
      t.string :mon, limit: 255, null: false
      t.string :mon_pdf, limit: 255, null: false
      t.string :ov_pdf, limit: 255, null: false
      t.string :reflex, limit: 255, null: false
      t.string :chamber, limit: 255, null: false
      t.string :senate, limit: 255, null: false
      t.integer :language_id, null: false
      t.string :tags, limit: 255
      t.integer :is_abolished, default: 0
      t.integer :is_empty_content, default: 0
      t.integer :translation_missing, default: 0
      t.string :original_created_at, limit: 50
      t.string :original_updated_at, limit: 50
      t.datetime :archived_at, null: false
      t.string :reason, limit: 255, null: false
      
      t.index :numac
      t.index :archived_at
      t.index :reason
    end
  end
end
