class CreateArticleModifications < ActiveRecord::Migration[8.0]
  def change
    create_table :article_modifications do |t|
      t.integer :language_id, null: false
      t.string :content_numac, limit: 10, null: false
      t.string :article_title, limit: 50, null: false
      t.string :change_type, limit: 20, null: false  # 'modified', 'abolished', 'created', 'replaced'
      t.date :effective_date, null: false
      t.date :publication_date
      t.string :modifying_numac, limit: 10  # Law that caused this change
      t.string :modifying_law_type, limit: 20  # WET, KB, DECREET, etc.
      t.timestamps
    end

    # Find modifications for a specific article
    add_index :article_modifications, [:content_numac, :article_title, :effective_date],
              name: 'idx_article_mods_lookup'
    
    # Find abolished articles
    add_index :article_modifications, [:content_numac, :change_type],
              name: 'idx_article_mods_change_type'
    
    # Find what a specific law modified
    add_index :article_modifications, :modifying_numac
    
    # Language filtering
    add_index :article_modifications, :language_id
  end
end
