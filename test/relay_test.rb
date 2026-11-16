require_relative "test_helper"
require "logger"
require "ferry/relay"

class RelayTest < Minitest::Test
  class FakeStore
    attr_reader :failures

    def initialize
      @chats = {}
      @outbox = []
      @last_id = 0
      @failures = []
    end

    def enqueue(max_chat_id:, direction:, source_id:, payload:)
      chat = (@chats[max_chat_id] ||= { "id" => @chats.size + 1, "max_chat_id" => max_chat_id, "tg_topic_id" => nil })
      unless @outbox.any? { _1["direction"] == direction && _1["source_id"] == source_id }
        @outbox << { "id" => (@last_id += 1), "chat_id" => chat["id"], "direction" => direction,
                     "source_id" => source_id, "payload" => payload.to_json }
      end
      chat
    end

    def chat(id) = @chats.values.find { _1["id"] == id }

    def next_in_queue(chat_id, direction) = @outbox.find { _1["chat_id"] == chat_id && _1["direction"] == direction }

    def delete(id) = @outbox.reject! { _1["id"] == id }

    def set_topic(chat_id, topic_id, _title) = chat(chat_id)["tg_topic_id"] = topic_id

    def record_failure(id, message) = @failures << [id, message]

    def pending = @outbox.size
  end

  class FakeTelegram
    attr_reader :sent, :topics

    def initialize(failures: 0)
      @failures = failures
      @sent = []
      @topics = []
    end

    def create_topic(name)
      @topics << name
      100 + @topics.size
    end

    def send_message(topic_id:, text:)
      if @failures.positive?
        @failures -= 1
        raise Ferry::ApiError, "telegram is down"
      end
      @sent << [topic_id, text]
    end
  end

  class FakeMax
    def get_chat(_chat_id) = { "title" => "Семья" }
  end

  def setup
    @store = FakeStore.new
  end

  def test_dialog_message_creates_topic_named_after_author
    telegram = FakeTelegram.new

    relay(telegram).handle_max_update(update(text: "привет", chat_type: "dialog", chat_id: 5))

    assert_equal ["Иван Петров"], telegram.topics
    assert_equal [[101, "Иван Петров: привет"]], telegram.sent
    assert_equal 0, @store.pending
  end

  def test_group_message_uses_chat_title_and_reuses_topic
    telegram = FakeTelegram.new
    relay = relay(telegram)

    relay.handle_max_update(update(text: "раз", mid: "m1"))
    relay.handle_max_update(update(text: "два", mid: "m2"))

    assert_equal ["Семья"], telegram.topics
    assert_equal [[101, "Иван Петров: раз"], [101, "Иван Петров: два"]], telegram.sent
  end

  def test_failed_message_stays_in_queue_and_order_is_kept
    telegram = FakeTelegram.new(failures: 2)
    relay = relay(telegram)

    relay.handle_max_update(update(text: "раз", mid: "m1"))

    assert_equal 1, @store.pending
    assert_equal 1, @store.failures.size
    assert_empty telegram.sent

    relay.handle_max_update(update(text: "два", mid: "m2"))

    assert_equal 2, @store.pending
    assert_empty telegram.sent

    relay.handle_max_update(update(text: "три", mid: "m3"))

    assert_equal 0, @store.pending
    assert_equal ["Иван Петров: раз", "Иван Петров: два", "Иван Петров: три"], telegram.sent.map(&:last)
  end

  def test_skipped_messages_are_not_queued
    telegram = FakeTelegram.new
    relay = relay(telegram)

    relay.handle_max_update(update(text: "от бота", sender: { "user_id" => 9, "first_name" => "Bot", "is_bot" => true }))
    relay.handle_max_update(update(text: nil))
    relay.handle_max_update(update(text: "канал", chat_type: "channel"))
    relay.handle_max_update(update(text: "без чата", chat_id: nil))
    relay.handle_max_update({ "update_type" => "bot_started", "chat_id" => -77 })

    assert_equal 0, @store.pending
    assert_empty telegram.topics
    assert_empty telegram.sent
  end

  def test_author_falls_back_to_username_then_id
    telegram = FakeTelegram.new
    relay = relay(telegram)

    relay.handle_max_update(update(text: "a", mid: "m1", sender: { "user_id" => 7, "username" => "ivan_p" }))
    relay.handle_max_update(update(text: "b", mid: "m2", sender: { "user_id" => 7 }))

    assert_equal ["ivan_p: a", "id7: b"], telegram.sent.map(&:last)
  end

  private

  def relay(telegram)
    Ferry::Relay.new(store: @store, telegram: telegram, max: FakeMax.new, logger: Logger.new(nil))
  end

  def update(text:, chat_type: "chat", chat_id: -77, mid: "m1",
             sender: { "user_id" => 1, "first_name" => "Иван", "last_name" => "Петров", "is_bot" => false })
    {
      "update_type" => "message_created",
      "message" => {
        "sender" => sender,
        "recipient" => { "chat_id" => chat_id, "chat_type" => chat_type },
        "body" => { "mid" => mid, "text" => text }
      }
    }
  end
end