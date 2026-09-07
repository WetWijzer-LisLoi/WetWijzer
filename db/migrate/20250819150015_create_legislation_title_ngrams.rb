# frozen_string_literal: true

# Creates an n-gram (3-gram) inverted index for legislation.title to support fast substring search.
# This is SQLite-specific. On other adapters it no-ops.
class CreateLegislationTitleNgrams < ActiveRecord::Migration[8.0]
  GRAM_LEN = 3

  def up
    return say("Skipping legislation_title_ngrams creation: not SQLite adapter") unless sqlite?

    execute "PRAGMA busy_timeout = 5000;"

    execute <<~SQL
      CREATE TABLE IF NOT EXISTS legislation_title_ngrams (
        rowid INTEGER NOT NULL,
        gram  TEXT    NOT NULL,
        PRIMARY KEY (rowid, gram)
      ) WITHOUT ROWID;
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_legislation_title_ngrams_gram ON legislation_title_ngrams(gram);
    SQL

    # Triggers: maintain grams on INSERT/UPDATE/DELETE of legislation
    # We generate grams using a recursive CTE. We store distinct grams per row.
    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS legislation_tngrams_ai AFTER INSERT ON legislation BEGIN
        INSERT OR IGNORE INTO legislation_title_ngrams(rowid, gram)
        WITH RECURSIVE
          base(t) AS (SELECT lower(new.title)),
          spans(i, t) AS (
            SELECT 1, t FROM base WHERE length(t) >= #{GRAM_LEN}
            UNION ALL
            SELECT i+1, t FROM spans WHERE i+#{GRAM_LEN-1} <= length(t)
          )
        SELECT new.rowid, substr(t, i, #{GRAM_LEN}) AS gram FROM spans GROUP BY gram;
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS legislation_tngrams_ad AFTER DELETE ON legislation BEGIN
        DELETE FROM legislation_title_ngrams WHERE rowid = old.rowid;
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS legislation_tngrams_au AFTER UPDATE OF title ON legislation BEGIN
        DELETE FROM legislation_title_ngrams WHERE rowid = old.rowid;
        INSERT OR IGNORE INTO legislation_title_ngrams(rowid, gram)
        WITH RECURSIVE
          base(t) AS (SELECT lower(new.title)),
          spans(i, t) AS (
            SELECT 1, t FROM base WHERE length(t) >= #{GRAM_LEN}
            UNION ALL
            SELECT i+1, t FROM spans WHERE i+#{GRAM_LEN-1} <= length(t)
          )
        SELECT new.rowid, substr(t, i, #{GRAM_LEN}) AS gram FROM spans GROUP BY gram;
      END;
    SQL

    say "legislation_title_ngrams created. Backfill via rake ngram:backfill_titles for best performance."
  end

  def down
    return say("Skipping drop: not SQLite adapter") unless sqlite?

    execute "DROP TRIGGER IF EXISTS legislation_tngrams_ai;"
    execute "DROP TRIGGER IF EXISTS legislation_tngrams_ad;"
    execute "DROP TRIGGER IF EXISTS legislation_tngrams_au;"
    execute "DROP INDEX IF EXISTS idx_legislation_title_ngrams_gram;"
    execute "DROP TABLE IF EXISTS legislation_title_ngrams;"
  end

  private

  def sqlite?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.start_with?("sqlite")
  end
end
