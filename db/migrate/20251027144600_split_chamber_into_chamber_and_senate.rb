class SplitChamberIntoChamberAndSenate < ActiveRecord::Migration[8.0]
  def up
    # Add new senate column
    add_column :legislation, :senate, :string, limit: 80, null: false, default: ''
    
    # Split existing chamber data: chamber contains "chamber_url | senate_url"
    # Extract senate URL and move it to new column
    execute <<-SQL
      UPDATE legislation
      SET senate = SUBSTR(chamber, INSTR(chamber, ' | ') + 3),
          chamber = SUBSTR(chamber, 1, INSTR(chamber, ' | ') - 1)
      WHERE chamber LIKE '% | %'
    SQL
    
    # For records without pipe separator, chamber stays as is, senate remains empty
  end
  
  def down
    # Merge senate back into chamber column
    execute <<-SQL
      UPDATE legislation
      SET chamber = chamber || ' | ' || senate
      WHERE senate != ''
    SQL
    
    remove_column :legislation, :senate
  end
end
