class CreateSongs < ActiveRecord::Migration[6.0]
  def up
    create_table :songs do |t|
      t.string  :title
      t.string  :artist
      t.string  :album
      t.string  :genre
      t.integer :year
      t.string  :filepath, null: false
      t.integer :duration
      t.string  :category
      t.timestamps
    end

    add_index :songs, :filepath, unique: true
    add_index :songs, :artist
    add_index :songs, :genre

    execute <<-SQL
      CREATE VIRTUAL TABLE songs_fts USING fts5(
        title, artist, album, genre, category,
        content='songs',
        content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
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
  end

  def down
    execute "DROP TRIGGER IF EXISTS songs_au"
    execute "DROP TRIGGER IF EXISTS songs_ad"
    execute "DROP TRIGGER IF EXISTS songs_ai"
    execute "DROP TABLE IF EXISTS songs_fts"
    drop_table :songs
  end
end
