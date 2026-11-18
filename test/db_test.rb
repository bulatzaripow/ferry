require_relative "test_helper"
require "ferry/db"

class DBTest < Minitest::Test
  def setup
    @db = Ferry::DB.connect(":memory:")
  end

  def test_applies_all_migrations
    version = @db.get_first_value("PRAGMA user_version")
    tables = @db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map { _1["name"] }

    assert_equal Ferry::DB.migration_files.size, version
    assert_includes tables, "chats"
    assert_includes tables, "outbox"
  end

  def test_migrate_twice_changes_nothing
    Ferry::DB.migrate(@db)

    assert_equal Ferry::DB.migration_files.size, @db.get_first_value("PRAGMA user_version")
  end

  def test_outbox_rejects_duplicate_source_id
    chat_id = create_chat
    add_to_outbox(chat_id, "m1")

    assert_raises(SQLite3::ConstraintException) { add_to_outbox(chat_id, "m1") }
  end

  def test_outbox_requires_existing_chat
    assert_raises(SQLite3::ConstraintException) { add_to_outbox(999, "m1") }
  end

  private

  def create_chat
    @db.execute("INSERT INTO chats (max_chat_id) VALUES (?)", [100])
    @db.last_insert_row_id
  end

  def add_to_outbox(chat_id, source_id)
    @db.execute(
      "INSERT INTO outbox (chat_id, direction, source_id, payload) VALUES (?, 'max_to_tg', ?, '{}')",
      [chat_id, source_id]
    )
  end
end