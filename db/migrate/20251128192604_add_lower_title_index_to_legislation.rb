class AddLowerTitleIndexToLegislation < ActiveRecord::Migration[8.0]
  def change
    # Add functional index on LOWER(title) for case-insensitive searches
    # This optimizes the popular_law_path lookup query
    add_index :legislation, 
              'language_id, LOWER(title)',
              name: 'index_legislation_on_language_id_and_lower_title',
              where: "tags IS NOT NULL AND tags != ''"
  end
end
