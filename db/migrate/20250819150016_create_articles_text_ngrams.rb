# frozen_string_literal: true

# Creates an n-gram (3-gram) inverted index for articles.article_text to support fast substring search.
# This is SQLite-specific. On other adapters it no-ops.
class CreateArticlesTextNgrams < ActiveRecord::Migration[8.0]
  GRAM_LEN = 3

  def up
    return say("Skipping articles_text_ngrams creation: not SQLite adapter") unless sqlite?

    execute "PRAGMA busy_timeout = 5000;"

    execute <<~SQL
      CREATE TABLE IF NOT EXISTS articles_text_ngrams (
        rowid INTEGER NOT NULL,
        gram  TEXT    NOT NULL,
        PRIMARY KEY (rowid, gram)
      ) WITHOUT ROWID;
    SQL

    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_articles_text_ngrams_gram ON articles_text_ngrams(gram);
    SQL

    # Triggers: maintain grams on INSERT/UPDATE/DELETE of articles
    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS articles_tngrams_ai AFTER INSERT ON articles BEGIN
        INSERT OR IGNORE INTO articles_text_ngrams(rowid, gram)
        WITH RECURSIVE
          base(t) AS (SELECT lower(new.article_text)),
          spans(i, t) AS (
            SELECT 1, t FROM base WHERE length(t) >= #{GRAM_LEN}
            UNION ALL
            SELECT i+1, t FROM spans WHERE i+#{GRAM_LEN-1} <= length(t)
          )
        SELECT new.rowid, substr(t, i, #{GRAM_LEN}) AS gram FROM spans GROUP BY gram;
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS articles_tngrams_ad AFTER DELETE ON articles BEGIN
        DELETE FROM articles_text_ngrams WHERE rowid = old.rowid;
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS articles_tngrams_au AFTER UPDATE OF article_text ON articles BEGIN
        DELETE FROM articles_text_ngrams WHERE rowid = old.rowid;
        INSERT OR IGNORE INTO articles_text_ngrams(rowid, gram)
        WITH RECURSIVE
          base(t) AS (SELECT lower(new.article_text)),
          spans(i, t) AS (
            SELECT 1, t FROM base WHERE length(t) >= #{GRAM_LEN}
            UNION ALL
            SELECT i+1, t FROM spans WHERE i+#{GRAM_LEN-1} <= length(t)
          )
        SELECT new.rowid, substr(t, i, #{GRAM_LEN}) AS gram FROM spans GROUP BY gram;
      END;
    SQL

    say "articles_text_ngrams created. Backfill via rake ngram:backfill_articles for best performance."
  end

  def down
    return say("Skipping drop: not SQLite adapter") unless sqlite?

    execute "DROP TRIGGER IF EXISTS articles_tngrams_ai;"
    execute "DROP TRIGGER IF EXISTS articles_tngrams_ad;"
    execute "DROP TRIGGER IF EXISTS articles_tngrams_au;"
    execute "DROP INDEX IF EXISTS idx_articles_text_ngrams_gram;"
    execute "DROP TABLE IF EXISTS articles_text_ngrams;"
  end

  private

  def sqlite?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.start_with?("sqlite")
  end
end
