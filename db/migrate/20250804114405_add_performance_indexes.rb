class AddPerformanceIndexes < ActiveRecord::Migration[8.0]
  def change
    # Add indexes for frequently queried columns in legislation table
    add_index :legislation, :title
    add_index :legislation, :date
    add_index :legislation, :law_type_id
    add_index :legislation, :year
    
    # Add composite indexes for common query patterns
    add_index :legislation, [:language_id, :law_type_id]
    add_index :legislation, [:language_id, :date]
    add_index :legislation, [:language_id, :title]
    
    # Add indexes for content table
    add_index :contents, :language_id
    add_index :contents, [:language_id, :legislation_numac]
    
    # Add indexes for articles table
    add_index :articles, :language_id
    add_index :articles, [:language_id, :content_numac]
    
    # Add indexes for exdecs table
    add_index :exdecs, :language_id
    add_index :exdecs, [:language_id, :content_numac]
    
    # Add indexes for updated_laws table
    add_index :updated_laws, :language_id
    add_index :updated_laws, [:language_id, :content_numac]
  end
end
