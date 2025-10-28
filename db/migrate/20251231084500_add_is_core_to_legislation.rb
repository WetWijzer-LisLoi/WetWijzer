# frozen_string_literal: true

class AddIsCoreToLegislation < ActiveRecord::Migration[8.0]
  def change
    add_column :legislation, :is_core, :boolean, default: false, null: false
    add_index :legislation, :is_core, where: 'is_core = 1', name: 'index_legislation_on_is_core_true'
  end
end
