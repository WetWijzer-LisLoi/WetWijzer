class AddJustelSectionsToContents < ActiveRecord::Migration[8.0]
  def change
    add_column :contents, :preamble, :text unless column_exists?(:contents, :preamble)
    add_column :contents, :signature, :text unless column_exists?(:contents, :signature)
    add_column :contents, :parliamentary_work, :text unless column_exists?(:contents, :parliamentary_work)
    add_column :contents, :report_to_king, :text unless column_exists?(:contents, :report_to_king)
  end
end
