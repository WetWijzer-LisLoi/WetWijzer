class AddExternalLinksToContents < ActiveRecord::Migration[8.0]
  def change
    # Stores JSON array of external reference links (EUR-Lex, treaties, other external databases)
    # Structure: [{"label": "EUR-Lex - Directive 2000/78", "url": "http://...", "type": "eur-lex"}, ...]
    # Types: eur-lex, treaty, other
    add_column :contents, :other_external_links, :text, null: true
  end
end
