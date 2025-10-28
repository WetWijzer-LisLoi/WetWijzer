class AddLegislationFlagsIndex < ActiveRecord::Migration[8.0]
  def change
    # Composite index for filtering by status flags
    # Used in search when filtering out abolished/empty laws
    add_index :legislation, [:is_abolished, :is_empty_content, :translation_missing],
              name: 'idx_legislation_flags'
  end
end
