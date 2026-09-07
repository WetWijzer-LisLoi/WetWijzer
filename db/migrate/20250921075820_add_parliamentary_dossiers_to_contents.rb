class AddParliamentaryDossiersToContents < ActiveRecord::Migration[8.0]
  def change
    change_table :contents, bulk: true do |t|
      t.string :senate_dossier, limit: 32
      t.string :chamber_dossier, limit: 32
    end

    add_index :contents, :senate_dossier
    add_index :contents, :chamber_dossier
  end
end
