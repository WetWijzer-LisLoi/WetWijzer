# frozen_string_literal: true

class AddFisconetCoreLegislation < ActiveRecord::Migration[8.0]
  def up
    # Insert stub Legislation rows for FisconetPlus tax codes so they get
    # the is_core flag and appear as core laws in search ranking.
    # The actual article content is served from the separate fisconet.sqlite3.
    now = Time.current.iso8601

    [
      { numac: 'FISCONET_1', lang: 1, title: 'Wetboek van de Inkomstenbelastingen 1992 (WIB 92)' },
      { numac: 'FISCONET_1', lang: 2, title: "Code des impôts sur les revenus 1992 (CIR 92)" },
      { numac: 'FISCONET_2', lang: 1, title: 'KB tot uitvoering van het WIB 92 (KB/WIB 92)' },
      { numac: 'FISCONET_2', lang: 2, title: "AR d'exécution du CIR 92 (AR/CIR 92)" },
    ].each do |entry|
      execute <<~SQL.squish
        INSERT OR IGNORE INTO legislation
          (numac, law_type_id, year, date, title, justel, mon, mon_pdf, ov_pdf, reflex, chamber, language_id, is_core, is_abolished, is_empty_content, created_at, updated_at)
        VALUES
          ('#{entry[:numac]}', 2, 1992, '1992-01-01', '#{entry[:title].gsub("'", "''")}',
           'N/A', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A',
           #{entry[:lang]}, 1, 0, 0, '#{now}', '#{now}')
      SQL
    end
  end

  def down
    execute "DELETE FROM legislation WHERE numac IN ('FISCONET_1', 'FISCONET_2')"
  end
end
