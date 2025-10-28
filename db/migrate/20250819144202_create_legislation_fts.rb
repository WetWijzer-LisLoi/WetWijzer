# frozen_string_literal: true

# Creates an SQLite FTS5 virtual table for fast full-text search on legislation titles
# and sets up triggers to keep it synchronized with the `legislation` table.
#
# Notes:
# - This migration is a no-op on non-SQLite adapters.
# - On SQLite, it uses an "external content" FTS5 table bound to `legislation` via rowid.
class CreateLegislationFts < ActiveRecord::Migration[8.0]
  def up
    return say("Skipping legislation_fts creation: not SQLite adapter") unless sqlite?

    # Mitigate transient lock errors during migration by waiting for busy DB
    execute "PRAGMA busy_timeout = 5000;"

    # Create virtual FTS5 table backed by `legislation` content table
    execute <<~SQL
      CREATE VIRTUAL TABLE IF NOT EXISTS legislation_fts USING fts5(
        title,
        content = 'legislation',
        content_rowid = 'rowid'
      );
    SQL

    # Backfill FTS index from existing rows
    execute <<~SQL
      INSERT INTO legislation_fts(rowid, title)
      SELECT rowid, title FROM legislation;
    SQL

    # Triggers to keep FTS in sync
    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS legislation_ai AFTER INSERT ON legislation BEGIN
        INSERT INTO legislation_fts(rowid, title)
        VALUES (new.rowid, new.title);
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS legislation_ad AFTER DELETE ON legislation BEGIN
        INSERT INTO legislation_fts(legislation_fts, rowid, title)
        VALUES ('delete', old.rowid, old.title);
      END;
    SQL

    execute <<~SQL
      CREATE TRIGGER IF NOT EXISTS legislation_au AFTER UPDATE ON legislation BEGIN
        INSERT INTO legislation_fts(legislation_fts, rowid, title)
        VALUES ('delete', old.rowid, old.title);
        INSERT INTO legislation_fts(rowid, title)
        VALUES (new.rowid, new.title);
      END;
    SQL
  end

  def down
    return say("Skipping legislation_fts drop: not SQLite adapter") unless sqlite?

    execute <<~SQL
      DROP TRIGGER IF EXISTS legislation_ai;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS legislation_ad;
    SQL

    execute <<~SQL
      DROP TRIGGER IF EXISTS legislation_au;
    SQL

    execute <<~SQL
      DROP TABLE IF EXISTS legislation_fts;
    SQL
  end

  private

  def sqlite?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.start_with?("sqlite")
  end
end
