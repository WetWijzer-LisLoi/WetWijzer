# frozen_string_literal: true

# Creates an SQLite FTS5 virtual table for fast full-text search on articles
# and sets up triggers to keep it synchronized with the `articles` table.
#
# Notes:
# - This migration is a no-op on non-SQLite adapters.
# - On SQLite, it uses an "external content" FTS5 table bound to `articles` via rowid.
# - We index only `article_title` and `article_text`. Filtering (e.g., by language)
#   should be done by joining the FTS matches back to `articles`.
class CreateArticlesFts < ActiveRecord::Migration[8.0]
  def up
    return say("Skipping articles_fts creation: not SQLite adapter") unless sqlite?
    
    # Mitigate transient lock errors during migration by waiting for busy DB
    execute "PRAGMA busy_timeout = 5000;"

    # Create virtual FTS5 table backed by `articles` content table
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(
        article_title,
        article_text,
        content = 'articles',
        content_rowid = 'rowid'
      );
    SQL

    # Backfill FTS index from existing rows
    execute <<~SQL
      INSERT INTO articles_fts(rowid, article_title, article_text)
      SELECT rowid, article_title, article_text FROM articles;
    SQL

    # Triggers to keep FTS in sync
    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS articles_ai AFTER INSERT ON articles BEGIN
        INSERT INTO articles_fts(rowid, article_title, article_text)
        VALUES (new.rowid, new.article_title, new.article_text);
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS articles_ad AFTER DELETE ON articles BEGIN
        INSERT INTO articles_fts(articles_fts, rowid, article_title, article_text)
        VALUES ('delete', old.rowid, old.article_title, old.article_text);
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS articles_au AFTER UPDATE ON articles BEGIN
        INSERT INTO articles_fts(articles_fts, rowid, article_title, article_text)
        VALUES ('delete', old.rowid, old.article_title, old.article_text);
        INSERT INTO articles_fts(rowid, article_title, article_text)
        VALUES (new.rowid, new.article_title, new.article_text);
      END;
    SQL
  end

  def down
    return say("Skipping articles_fts drop: not SQLite adapter") unless sqlite?

    execute <<~SQL
      DROP TRIGGER IF EXISTS articles_ai;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS articles_ad;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS articles_au;
    SQL

    execute <<~SQL
      DROP TABLE IF EXISTS articles_fts;
    SQL
  end

  private

  def sqlite?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.start_with?("sqlite")
  end
end
