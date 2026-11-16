require_relative "test_helper"
require "logger"
require "ferry/relay"

class RelayTest < Minitest::Test
  OWNER = 42
  GROUP = -100

  class FakeStore
    attr_reader :failures

    def initialize
      @chats = {}
      @outbox = []
      @last_id = 0
      @failures = []
    end

    def enqueue(max_chat_id:, direction:, items:)
      chat = (@chats[max_chat_id] ||= { "id" => @chats.size + 1, "max_chat_id" => max_chat_id, "tg_topic_id" => nil })
      items.each do |source_id, payload|
        next if @outbox.any? { _1["direction"] == direction && _1["source_id"] == source_id }

        @outbox << { "id" => (@last_id += 1), "chat_id" => chat["id"], "direction" => direction,
                     "source_id" => source_id, "payload" => payload.to_json }
      end
      chat
    end

    def chat(id) = @chats.values.find { _1["id"] == id }

    def chat_by_topic(topic_id) = @chats.values.find { _1["tg_topic_id"] == topic_id }

    def next_in_queue(chat_id, direction) = @outbox.find { _1["chat_id"] == chat_id && _1["direction"] == direction }

    def delete(id) = @outbox.reject! { _1["id"] == id }

    def set_topic(chat_id, topic_id, _title) = chat(chat_id)["tg_topic_id"] = topic_id

    def record_failure(id, message) = @failures << [id, message]

    def pending(direction = nil) = @outbox.count { direction.nil? || _1["direction"] == direction }
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
    attr_reader :sent

    def initialize(failures: 0)
      @failures = failures
      @sent = []
    end

    def get_chat(_chat_id) = { "title" => "Семья" }

    def send_message(chat_id:, text:)
      if @failures.positive?
        @failures -= 1
        raise Ferry::ApiError, "max is down"
      end
      @sent << [chat_id, text]
    end
  end

  def setup
    @store = FakeStore.new
    @telegram = FakeTelegram.new
    @max = FakeMax.new
  end

  # ---- Max -> Telegram

  def test_dialog_message_creates_topic_named_after_author
    relay.handle_max_update(max_update(text: "привет", chat_type: "dialog", chat_id: 5))

    assert_equal ["Иван Петров"], @telegram.topics
    assert_equal [[101, "Иван Петров: привет"]], @telegram.sent
    assert_equal 0, @store.pending
  end

  def test_group_message_uses_chat_title_and_reuses_topic
    relay.handle_max_update(max_update(text: "раз", mid: "m1"))
    relay.handle_max_update(max_update(text: "два", mid: "m2"))

    assert_equal ["Семья"], @telegram.topics
    assert_equal [[101, "Иван Петров: раз"], [101, "Иван Петров: два"]], @telegram.sent
  end

  def test_failed_message_stays_in_queue_and_order_is_kept
    @telegram = FakeTelegram.new(failures: 2)
    relay = relay()

    relay.handle_max_update(max_update(text: "раз", mid: "m1"))

    assert_equal 1, @store.pending
    assert_equal 1, @store.failures.size
    assert_empty @telegram.sent

    relay.handle_max_update(max_update(text: "два", mid: "m2"))

    assert_equal 2, @store.pending
    assert_empty @telegram.sent

    relay.handle_max_update(max_update(text: "три", mid: "m3"))

    assert_equal 0, @store.pending
    assert_equal ["Иван Петров: раз", "Иван Петров: два", "Иван Петров: три"], @telegram.sent.map(&:last)
  end

  def test_long_max_message_is_split_in_order
    relay.handle_max_update(max_update(text: "а" * 3800 + "б" * 100))

    assert_equal ["Иван Петров: " + "а" * 3800, "Иван Петров: " + "б" * 100], @telegram.sent.map(&:last)
  end

  def test_skipped_max_messages_are_not_queued
    relay = relay()

    relay.handle_max_update(max_update(text: "от бота", sender: { "user_id" => 9, "first_name" => "Bot", "is_bot" => true }))
    relay.handle_max_update(max_update(text: nil))
    relay.handle_max_update(max_update(text: "канал", chat_type: "channel"))
    relay.handle_max_update(max_update(text: "без чата", chat_id: nil))
    relay.handle_max_update({ "update_type" => "bot_started", "chat_id" => -77 })

    assert_equal 0, @store.pending
    assert_empty @telegram.topics
    assert_empty @telegram.sent
  end

  def test_author_falls_back_to_username_then_id
    relay = relay()

    relay.handle_max_update(max_update(text: "a", mid: "m1", sender: { "user_id" => 7, "username" => "ivan_p" }))
    relay.handle_max_update(max_update(text: "b", mid: "m2", sender: { "user_id" => 7 }))

    assert_equal ["ivan_p: a", "id7: b"], @telegram.sent.map(&:last)
  end

  # ---- Telegram -> Max

  def test_owner_message_in_topic_goes_to_max
    relay = relay_with_topic

    relay.handle_telegram_update(telegram_update(text: "ответ"))

    assert_equal [[-77, "ответ"]], @max.sent
    assert_equal 0, @store.pending
  end

  def test_long_telegram_message_is_split_in_order
    relay = relay_with_topic

    relay.handle_telegram_update(telegram_update(text: "а" * 3800 + "б" * 3800 + "в" * 10))

    assert_equal ["а" * 3800, "б" * 3800, "в" * 10], @max.sent.map(&:last)
  end

  def test_failed_telegram_message_blocks_later_ones_but_keeps_order
    @max = FakeMax.new(failures: 1)
    relay = relay_with_topic

    relay.handle_telegram_update(telegram_update(text: "раз", id: 1))

    assert_empty @max.sent
    assert_equal 1, @store.pending("tg_to_max")

    relay.handle_telegram_update(telegram_update(text: "два", id: 2))

    assert_equal ["раз", "два"], @max.sent.map(&:last)
    assert_equal 0, @store.pending
  end

  def test_max_outage_does_not_block_max_to_telegram_direction
    @max = FakeMax.new(failures: 100)
    relay = relay_with_topic

    relay.handle_telegram_update(telegram_update(text: "ответ"))
    relay.handle_max_update(max_update(text: "новое", mid: "m2"))

    assert_equal 1, @store.pending("tg_to_max")
    assert_equal ["Иван Петров: старт", "Иван Петров: новое"], @telegram.sent.map(&:last)
  end

  def test_telegram_messages_that_must_not_be_forwarded
    relay = relay_with_topic

    relay.handle_telegram_update(telegram_update(text: "чужой", from: 7))
    relay.handle_telegram_update(telegram_update(text: "другая группа", chat: -555))
    relay.handle_telegram_update(telegram_update(text: "вне темы", topic: nil))
    relay.handle_telegram_update(telegram_update(text: "неизвестная тема", topic: 999))
    relay.handle_telegram_update(telegram_update(text: nil))
    relay.handle_telegram_update({ "edited_message" => { "text" => "правка" } })

    assert_empty @max.sent
    assert_equal 0, @store.pending
  end

  private

  def relay = Ferry::Relay.new(store: @store, telegram: @telegram, max: @max,
                               owner_id: OWNER, group_id: GROUP, logger: Logger.new(nil))

  # чат Max -77 уже связан с темой Telegram 101 (тема создаётся первым сообщением из Max)
  def relay_with_topic
    relay.tap { _1.handle_max_update(max_update(text: "старт", mid: "m0")) }
  end

  def max_update(text:, chat_type: "chat", chat_id: -77, mid: "m1",
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

  def telegram_update(text:, id: 1, from: OWNER, chat: GROUP, topic: 101)
    { "message" => { "message_id" => id, "from" => { "id" => from }, "chat" => { "id" => chat },
                     "message_thread_id" => topic, "text" => text } }
  end
end