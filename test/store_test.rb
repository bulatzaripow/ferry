require_relative "test_helper"
require "ferry/db"
require "ferry/store"

class StoreTest < Minitest::Test
  def setup
    @store = Ferry::Store.new(Ferry::DB.connect(":memory:"))
  end

  def test_enqueue_creates_chat_and_reuses_it
    first = enqueue("m1")
    second = enqueue("m2")

    assert_equal first["id"], second["id"]
    assert_nil first["tg_topic_id"]
  end

  def test_enqueue_ignores_duplicate_source_id
    chat = enqueue("m1")
    enqueue("m1")

    assert_equal "m1", @store.next_in_queue(chat["id"], "max_to_tg")["source_id"]
    @store.delete(@store.next_in_queue(chat["id"], "max_to_tg")["id"])
    assert_nil @store.next_in_queue(chat["id"], "max_to_tg")
  end

  def test_queue_is_returned_oldest_first
    chat = enqueue("m1")
    enqueue("m2")

    assert_equal "m1", @store.next_in_queue(chat["id"], "max_to_tg")["source_id"]

    @store.delete(@store.next_in_queue(chat["id"], "max_to_tg")["id"])

    assert_equal "m2", @store.next_in_queue(chat["id"], "max_to_tg")["source_id"]
  end

  def test_payload_is_stored_as_json
    chat = enqueue("m1")

    payload = JSON.parse(@store.next_in_queue(chat["id"], "max_to_tg")["payload"])

    assert_equal({ "author" => "Иван", "text" => "привет" }, payload)
  end

  def test_set_topic
    chat = enqueue("m1")

    @store.set_topic(chat["id"], 55, "Семья")

    assert_equal 55, @store.chat(chat["id"])["tg_topic_id"]
    assert_equal "Семья", @store.chat(chat["id"])["title"]
  end

  def test_record_failure_counts_attempts
    chat = enqueue("m1")
    row = @store.next_in_queue(chat["id"], "max_to_tg")

    @store.record_failure(row["id"], "boom")
    @store.record_failure(row["id"], "boom again")

    row = @store.next_in_queue(chat["id"], "max_to_tg")
    assert_equal 2, row["attempts"]
    assert_equal "boom again", row["last_error"]
  end

  private

  def enqueue(source_id)
    @store.enqueue(max_chat_id: -77, direction: "max_to_tg", source_id: source_id,
                   payload: { author: "Иван", text: "привет" })
  end
end