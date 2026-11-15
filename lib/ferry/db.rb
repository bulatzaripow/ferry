require "fileutils"
require "sqlite3"

module Ferry
  module DB
    MIGRATIONS_DIR = File.expand_path("../../db/migrate", __dir__)

    def self.connect(path)
      FileUtils.mkdir_p(File.dirname(path))
      db = SQLite3::Database.new(path)
      db.results_as_hash = true
      db.busy_timeout = 5000
      db.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
      migrate(db)
      db
    end

    def self.migration_files
      Dir[File.join(MIGRATIONS_DIR, "*.sql")].sort
    end

    def self.migrate(db)
      applied = db.get_first_value("PRAGMA user_version")

      migration_files.each.with_index(1) do |file, version|
        next if version <= applied

        db.transaction do
          db.execute_batch(File.read(file))
          db.execute("PRAGMA user_version = #{version}")
        end
      end
    end
  end
end