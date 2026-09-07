class CreateSavedAnswers < ActiveRecord::Migration[8.0]
  def change
    create_table :saved_answers do |t|
      t.references :user, null: false, foreign_key: true
      t.string :question, limit: 1000, null: false
      t.text :answer, null: false
      t.json :sources
      t.string :language, limit: 5, default: 'nl'
      t.string :title, limit: 200  # Optional user-provided title
      t.string :category, limit: 50  # Optional categorization
      t.timestamps
    end

    add_index :saved_answers, [:user_id, :created_at]
    add_index :saved_answers, [:user_id, :category]
  end
end
