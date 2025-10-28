class CreateDocumentNumberLookups < ActiveRecord::Migration[8.0]
  def change
    create_table :document_number_lookups do |t|
      t.string :document_number, null: false
      t.string :numac, null: false
      t.integer :language_id, null: false, default: 1
      t.references :content, null: false, foreign_key: true

      t.timestamps
    end
    
    add_index :document_number_lookups, :document_number, unique: true
    add_index :document_number_lookups, :language_id
    add_index :document_number_lookups, :numac
  end
end
