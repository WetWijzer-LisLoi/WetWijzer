class AddIntrodFieldsToContents < ActiveRecord::Migration[8.1]
  def change
    add_column :contents, :publication_date, :string, limit: 32
    add_column :contents, :dossier_number, :string, limit: 20
    add_column :contents, :page_number, :string, limit: 10
    add_column :contents, :source, :string, limit: 300
    add_column :contents, :effective_date, :string, limit: 50
    add_column :contents, :end_of_validity, :string, limit: 50
    add_column :contents, :erratum, :text
  end
end
