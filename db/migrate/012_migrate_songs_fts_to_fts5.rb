require 'sqlite3'
require 'yaml'

class MigrateSongsFtsToFts5 < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    # Check if songs_fts already uses fts5 — no-op on fresh DBs where migration 010
    # already creates fts5, or if this was run before.
    current = connection.select_value("SELECT sql FROM sqlite_master WHERE name='songs_fts'").to_s
    return if current.include?('fts5')

    if current.include?('fts4')
      # fts4 cannot be dropped by sqlite3 >= 2.x (compiled without fts4 module).
      # Work around by operating on the DB file directly with a separate raw connection,
      # then reconnecting AR so it sees a clean schema.
      db_path = ActiveRecord::Base.connection.raw_connection.filename
      ActiveRecord::Base.connection_pool.disconnect!

      SQLite3::Database.open(db_path) do |raw|
        raw.execute("DROP TRIGGER IF EXISTS songs_au")
        raw.execute("DROP TRIGGER IF EXISTS songs_ad")
        raw.execute("DROP TRIGGER IF EXISTS songs_ai")
        raw.execute("PRAGMA writable_schema = ON")
        raw.execute("DELETE FROM sqlite_master WHERE name LIKE 'songs_fts%'")
        raw.execute("PRAGMA writable_schema = OFF")
        raw.execute("VACUUM")
      end

      config = YAML.load(IO.read(File.join(__dir__, '../../config/database.yml')))
      ActiveRecord::Base.establish_connection(config)
    end

    execute <<-SQL
      CREATE VIRTUAL TABLE songs_fts USING fts5(
        title, artist, album, genre, category,
        content='songs', content_rowid='id',
        tokenize='unicode61 remove_diacritics 1'
      );
    SQL

    execute <<-SQL
      CREATE TRIGGER songs_ai AFTER INSERT ON songs BEGIN
        INSERT INTO songs_fts(rowid, title, artist, album, genre, category)
        VALUES (new.id, new.title, new.artist, new.album, new.genre, new.category);
      END;
    SQL

    execute <<-SQL
      CREATE TRIGGER songs_ad AFTER DELETE ON songs BEGIN
        INSERT INTO songs_fts(songs_fts, rowid, title, artist, album, genre, category)
        VALUES ('delete', old.id, old.title, old.artist, old.album, old.genre, old.category);
      END;
    SQL

    execute <<-SQL
      CREATE TRIGGER songs_au AFTER UPDATE ON songs BEGIN
        INSERT INTO songs_fts(songs_fts, rowid, title, artist, album, genre, category)
        VALUES ('delete', old.id, old.title, old.artist, old.album, old.genre, old.category);
        INSERT INTO songs_fts(rowid, title, artist, album, genre, category)
        VALUES (new.id, new.title, new.artist, new.album, new.genre, new.category);
      END;
    SQL

    execute "INSERT INTO songs_fts(songs_fts) VALUES('rebuild')"
  end

  def down
    current = connection.select_value("SELECT sql FROM sqlite_master WHERE name='songs_fts'").to_s
    return if current.include?('fts4') || current.empty?

    execute "DROP TRIGGER IF EXISTS songs_au"
    execute "DROP TRIGGER IF EXISTS songs_ad"
    execute "DROP TRIGGER IF EXISTS songs_ai"
    execute "DROP TABLE IF EXISTS songs_fts"

    execute <<-SQL
      CREATE VIRTUAL TABLE songs_fts USING fts4(
        content="songs",
        title, artist, album, genre, category,
        tokenize=unicode61 "remove_diacritics=1"
      );
    SQL

    execute <<-SQL
      CREATE TRIGGER songs_ai AFTER INSERT ON songs BEGIN
        INSERT INTO songs_fts(docid, title, artist, album, genre, category)
        VALUES (new.id, new.title, new.artist, new.album, new.genre, new.category);
      END;
    SQL

    execute <<-SQL
      CREATE TRIGGER songs_ad AFTER DELETE ON songs BEGIN
        INSERT INTO songs_fts(songs_fts, docid, title, artist, album, genre, category)
        VALUES ('delete', old.id, old.title, old.artist, old.album, old.genre, old.category);
      END;
    SQL

    execute <<-SQL
      CREATE TRIGGER songs_au AFTER UPDATE ON songs BEGIN
        INSERT INTO songs_fts(songs_fts, docid, title, artist, album, genre, category)
        VALUES ('delete', old.id, old.title, old.artist, old.album, old.genre, old.category);
        INSERT INTO songs_fts(docid, title, artist, album, genre, category)
        VALUES (new.id, new.title, new.artist, new.album, new.genre, new.category);
      END;
    SQL

    execute "INSERT INTO songs_fts(songs_fts) VALUES('rebuild')"
  end
end
