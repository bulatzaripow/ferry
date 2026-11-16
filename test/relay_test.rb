require_relative "test_helper"
require_relative "fake_store"
require "logger"
require "ferry/relay"

class RelayTest < Minitest::Test
  OWNER = 42
  GROUP = -100

  class FakeWorker
    attr_reader :wakes

    def initialize
      @wakes = 0
    end

    def wake = @wakes += 1
  end

  def setup
    @store = FakeStore.new
    @worker = FakeWorker.new
    @relay = Ferry::Relay.new(store: @store, worker: @worker, owner_id: OWNER, group_id: GROUP, logger: Logger.new(nil))

    chat = @store.enqueue(max_chat_id: -77, direction: "tg_to_max", items: [])
    @store.set_topic(chat["id"], 101, "Family")
  end

  # ---- Max -> Telegram

  def test_max_message_is_queued_with_author_and_worker_is_woken
    @relay.handle_max_update(max_update(text: "hello", chat_type: "dialog", chat_id: 5))

    assert_equal ["m1:0"], @store.rows.map { _1["source_id"] }
    assert_equal({ "author" => "Ivan Petrov", "text" => "hello", "chat_type" => "dialog" }, payloads.first)
    assert_equal "max_to_tg", @store.rows.first["direction"]
    assert_equal 1, @worker.wakes
  end

  def test_repeated_webhook_does_not_duplicate_message
    2.times { @relay.handle_max_update(max_update(text: "hello")) }

    assert_equal 1, @store.pending
  end

  def test_long_max_message_is_split_in_order
    @relay.handle_max_update(max_update(text: "a" * 3800 + "b" * 100))

    assert_equal %w[m1:0 m1:1], @store.rows.map { _1["source_id"] }
    assert_equal ["a" * 3800, "b" * 100], payloads.map { _1["text"] }
  end

  def test_skipped_max_messages_are_not_queued
    @relay.handle_max_update(max_update(text: "from bot", sender: { "user_id" => 9, "first_name" => "Bot", "is_bot" => true }))
    @relay.handle_max_update(max_update(text: nil))
    @relay.handle_max_update(max_update(text: "channel", chat_type: "channel"))
    @relay.handle_max_update(max_update(text: "no chat", chat_id: nil))
    @relay.handle_max_update({ "update_type" => "bot_started", "chat_id" => -77 })

    assert_equal 0, @store.pending
    assert_equal 0, @worker.wakes
  end

  def test_author_falls_back_to_username_then_id
    @relay.handle_max_update(max_update(text: "a", mid: "m1", sender: { "user_id" => 7, "username" => "ivan_p" }))
    @relay.handle_max_update(max_update(text: "b", mid: "m2", sender: { "user_id" => 7 }))

    assert_equal %w[ivan_p id7], payloads.map { _1["author"] }
  end

  # ---- Telegram -> Max

  def test_owner_message_in_known_topic_is_queued_for_max
    @relay.handle_telegram_update(telegram_update(text: "reply", id: 5))

    row = @store.rows.first
    assert_equal "tg_to_max", row["direction"]
    assert_equal "5:0", row["source_id"]
    assert_equal({ "text" => "reply" }, payloads.first)
    assert_equal @store.chat_by_topic(101)["id"], row["chat_id"]
    assert_equal 1, @worker.wakes
  end

  def test_long_telegram_message_is_split_in_order
    @relay.handle_telegram_update(telegram_update(text: "a" * 3800 + "b" * 3800 + "c" * 10))

    assert_equal ["a" * 3800, "b" * 3800, "c" * 10], payloads.map { _1["text"] }
  end

  def test_telegram_messages_that_must_not_be_forwarded
    @relay.handle_telegram_update(telegram_update(text: "stranger", from: 7))
    @relay.handle_telegram_update(telegram_update(text: "other group", chat: -555))
    @relay.handle_telegram_update(telegram_update(text: "outside topic", topic: nil))
    @relay.handle_telegram_update(telegram_update(text: "unknown topic", topic: 999))
    @relay.handle_telegram_update(telegram_update(text: nil))
    @relay.handle_telegram_update({ "edited_message" => { "text" => "edit" } })

    assert_equal 0, @store.pending
    assert_equal 0, @worker.wakes
  end

  private

  def payloads = @store.rows.map { JSON.parse(_1["payload"]) }

  def max_update(text:, chat_type: "chat", chat_id: -77, mid: "m1",
                 sender: { "user_id" => 1, "first_name" => "Ivan", "last_name" => "Petrov", "is_bot" => false })
    {
      "update_type" => "message_created",
      "message" => {
        "sender" => sender,
        "recipient" => { "chat_id" => chat_id, "chat_type" => chat_type },
        "body" => { "mid" => mid, "text" => text }
      }
    }
  end

  def telegram_update(text:, id: 1, from: OWNER, chat: GROUP, topic: 101)
    { "message" => { "message_id" => id, "from" => { "id" => from }, "chat" => { "id" => chat },
                     "message_thread_id" => topic, "text" => text } }
  end
end