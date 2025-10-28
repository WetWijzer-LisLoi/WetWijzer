# frozen_string_literal: true

class AddShortTitleToLegislation < ActiveRecord::Migration[8.0]
  def change
    add_column :legislation, :short_title, :string, limit: 2000
  end
end
