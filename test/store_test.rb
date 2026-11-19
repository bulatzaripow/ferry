require_relative "test_helper"
require "ferry/db"
require "ferry/store"

class StoreTest < Minitest::Test
  FAR = 2**62

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

    @store.delete(head(chat)["id"])

    assert_nil head(chat)
  end

  def test_enqueue_several_items_keeps_their_order
    chat = enqueue("m1:0", "m1:1", "m1:2")

    ids = []
    while (row = head(chat))
      ids << row["source_id"]
      @store.delete(row["id"])
    end

    assert_equal %w[m1:0 m1:1 m1:2], ids
  end

  def test_due_returns_only_the_oldest_message_of_each_queue
    enqueue("m1", "m2")
    enqueue("t1", direction: "tg_to_max")
    enqueue("x1", chat: -78)

    assert_equal %w[m1 t1 x1], @store.due(FAR).map { _1["source_id"] }
  end

  def test_due_skips_queue_whose_oldest_message_is_waiting
    chat = enqueue("m1", "m2")
    @store.record_failure(head(chat)["id"], "boom", 100)

    assert_empty @store.due(99)
    assert_equal ["m1"], @store.due(100).map { _1["source_id"] }
  end

  def test_next_due_at
    assert_nil @store.next_due_at

    chat = enqueue("m1")
    @store.record_failure(head(chat)["id"], "boom", 100)

    assert_equal 100, @store.next_due_at

    enqueue("x1", chat: -78)

    assert_equal 0, @store.next_due_at
  end

  def test_record_failure_counts_attempts_and_saves_error
    chat = enqueue("m1")
    row = head(chat)

    @store.record_failure(row["id"], "boom", 10)
    @store.record_failure(row["id"], "boom again", 20)

    row = head(chat)
    assert_equal 2, row["attempts"]
    assert_equal "boom again", row["last_error"]
    assert_equal 20, row["next_attempt_at"]
  end

  def test_directions_have_separate_queues
    chat = enqueue("m1")
    enqueue("m1", direction: "tg_to_max")

    assert_equal "max_to_tg", head(chat)["direction"]
    assert_equal "tg_to_max", head(chat, "tg_to_max")["direction"]
  end

  def test_chat_by_topic_and_clear_topic
    chat = enqueue("m1")
    @store.set_topic(chat["id"], 55, "Family")

    assert_equal chat["id"], @store.chat_by_topic(55)["id"]
    assert_equal "Family", @store.chat(chat["id"])["title"]
    assert_nil @store.chat_by_topic(56)

    @store.clear_topic(chat["id"])

    assert_nil @store.chat_by_topic(55)
  end

  def test_payload_is_stored_as_json
    chat = enqueue("m1")

    assert_equal({ "author" => "Ivan", "text" => "hello" }, JSON.parse(head(chat)["payload"]))
  end

  # ---- albums

  def test_group_returns_all_rows_of_an_album_in_order
    chat = @store.enqueue(max_chat_id: -77, direction: "tg_to_max", due_at: 0,
                          items: [["1:0", { text: "a" }, "g1"], ["2:0", { text: "b" }, "g1"], ["3:0", { text: "c" }, "g2"], ["4:0", { text: "d" }]])

    head = head(chat, "tg_to_max")

    assert_equal %w[1:0 2:0], @store.group(head).map { _1["source_id"] }
  end

  def test_row_without_group_is_alone
    chat = enqueue("m1", "m2")

    assert_equal ["m1"], @store.group(head(chat)).map { _1["source_id"] }
  end

  def test_due_at_delays_the_first_attempt
    @store.enqueue(max_chat_id: -77, direction: "tg_to_max", items: [["1:0", { text: "a" }, "g1"]], due_at: 100)

    assert_empty @store.due(99)
    assert_equal ["1:0"], @store.due(100).map { _1["source_id"] }
    assert_equal 100, @store.next_due_at
  end

  # ---- links between the two messengers (for replies)

  def test_links_work_in_both_directions
    @store.link("mid.1", 501)

    assert_equal 501, @store.tg_message_id_for("mid.1")
    assert_equal "mid.1", @store.max_mid_for(501)
    assert_nil @store.tg_message_id_for("mid.2")
    assert_nil @store.max_mid_for(502)
  end

  def test_first_link_wins_when_one_message_is_split_into_parts
    @store.link("mid.1", 501)
    @store.link("mid.1", 502)

    assert_equal 501, @store.tg_message_id_for("mid.1")
    assert_nil @store.max_mid_for(502)
  end

  def test_old_links_are_dropped
    @store.link("mid.old", 501, 1000)
    @store.link("mid.new", 502, 1000 + Ferry::Store::LINK_TTL + 1)

    assert_nil @store.tg_message_id_for("mid.old")
    assert_equal 502, @store.tg_message_id_for("mid.new")
  end

  private

  def enqueue(*source_ids, direction: "max_to_tg", chat: -77)
    @store.enqueue(max_chat_id: chat, direction: direction,
                   items: source_ids.map { [_1, { author: "Ivan", text: "hello" }] })
  end

  def head(chat, direction = "max_to_tg")
    @store.due(FAR).find { _1["chat_id"] == chat["id"] && _1["direction"] == direction }
  end
end