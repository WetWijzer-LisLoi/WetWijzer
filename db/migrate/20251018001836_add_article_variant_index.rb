class AddArticleVariantIndex < ActiveRecord::Migration[8.0]
  def change
    # Index for filtering/grouping articles by variant
    add_index :articles, :article_variant, name: 'idx_articles_variant'
  end
end
