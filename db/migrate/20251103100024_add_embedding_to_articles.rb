class AddEmbeddingToArticles < ActiveRecord::Migration[8.0]
  def change
    add_column :articles, :embedding, :text
    add_column :articles, :embedding_generated_at, :datetime
    add_column :articles, :embedding_model, :string
  end
end
