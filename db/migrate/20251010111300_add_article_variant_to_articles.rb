class AddArticleVariantToArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :article_variant, :string, limit: 32
  end
end
