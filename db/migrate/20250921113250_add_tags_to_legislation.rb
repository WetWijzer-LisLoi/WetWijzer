# frozen_string_literal: true

class AddTagsToLegislation < ActiveRecord::Migration[8.0]
  def change
    add_column :legislation, :tags, :text
  end
end
