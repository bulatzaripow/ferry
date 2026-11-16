require_relative "test_helper"
require_relative "fake_store"
require "logger"
require "ferry/worker"

class WorkerTest < Minitest::Test
  class FakeTelegram
    attr_reader :sent, :topics

    def initialize(failures: 0, error: Ferry::ApiError.new("telegram is down"), gone_topics: [])
      @failures = failures
      @error = error
      @gone_topics = gone_topics
      @sent = []
      @topics = []
    end

    def create_topic(name)
      @topics << name
      100 + @topics.size
    end

    def send_message(topic_id:, text:)
      raise Ferry::ApiError.new("sendMessage: Bad Request: message thread not found", code: 400) if @gone_topics.include?(topic_id)

      if @failures.positive?
        @failures -= 1
        raise @error
      end
      @sent << [topic_id, text]
    end
  end

  class FakeMax
    attr_reader :sent

    def initialize(down_chats: [])
      @down_chats = down_chats
      @sent = []
    end

    def get_chat(_chat_id) = { "title" => "Family" }

    def send_message(chat_id:, text:)
      raise Ferry::ApiError, "max is down" if @down_chats.include?(chat_id)

      @sent << [chat_id, text]
    end
  end

  def setup
    @store = FakeStore.new
    @telegram = FakeTelegram.new
    @max = FakeMax.new
    @now = 1000
  end

  # ---- delivery

  def test_dialog_message_creates_topic_named_after_author_and_leaves_queue
    queue_for_telegram("hello", id: "m1", chat: 5, chat_type: "dialog")

    assert_equal 1, worker.tick

    assert_equal ["Ivan"], @telegram.topics
    assert_equal [[101, "Ivan: hello"]], @telegram.sent
    assert_equal 0, @store.pending
  end

  def test_group_message_uses_chat_title_and_topic_is_reused
    queue_for_telegram("one", id: "m1")
    queue_for_telegram("two", id: "m2")
    worker = worker()

    2.times { worker.tick }

    assert_equal ["Family"], @telegram.topics
    assert_equal [[101, "Ivan: one"], [101, "Ivan: two"]], @telegram.sent
  end

  def test_telegram_message_goes_to_max
    queue_for_max("answer", id: "1:0")

    worker.tick

    assert_equal [[-77, "answer"]], @max.sent
    assert_equal 0, @store.pending
  end

  def test_one_message_per_queue_per_round
    queue_for_telegram("one", id: "m1")
    queue_for_telegram("two", id: "m2")

    assert_equal 1, worker.tick
    assert_equal 1, @store.pending
  end

  # ---- повторы

  def test_failure_keeps_message_and_retries_with_growing_pause
    @telegram = FakeTelegram.new(failures: 3)
    queue_for_telegram("hello")
    worker = worker()

    worker.tick
    assert_equal [1, 1001, "telegram is down"], row_state

    assert_equal 0, worker.tick

    @now = 1001
    worker.tick
    assert_equal [2, 1003], row_state.first(2)

    @now = 1003
    worker.tick
    assert_equal [3, 1007], row_state.first(2)

    @now = 1007
    worker.tick
    assert_equal 0, @store.pending
    assert_equal [[101, "Ivan: hello"]], @telegram.sent
  end

  def test_pause_is_capped
    @telegram = FakeTelegram.new(failures: 100)
    queue_for_telegram("hello")
    worker = worker()

    12.times do
      @now = @store.rows.first["next_attempt_at"]
      worker.tick
    end

    assert_equal @now + 256, @store.rows.first["next_attempt_at"]
  end

  def test_retry_after_from_server_is_respected
    @telegram = FakeTelegram.new(failures: 1, error: Ferry::ApiError.new("429", code: 429, retry_after: 30))
    queue_for_telegram("hello")

    worker.tick

    assert_equal 1030, @store.rows.first["next_attempt_at"]
  end

  def test_order_is_kept_while_first_message_fails
    @telegram = FakeTelegram.new(failures: 1)
    queue_for_telegram("one", id: "m1")
    queue_for_telegram("two", id: "m2")
    worker = worker()

    worker.tick
    worker.tick

    assert_empty @telegram.sent
    assert_equal 2, @store.pending

    @now = 1001
    2.times { worker.tick }

    assert_equal ["Ivan: one", "Ivan: two"], @telegram.sent.map(&:last)
  end

  def test_failing_chat_does_not_block_other_chats
    @max = FakeMax.new(down_chats: [-1])
    queue_for_max("a", id: "1:0", chat: -1)
    queue_for_max("b", id: "2:0", chat: -2)

    worker.tick

    assert_equal [[-2, "b"]], @max.sent
    assert_equal 1, @store.pending
  end

  def test_directions_are_independent
    @max = FakeMax.new(down_chats: [-77])
    queue_for_max("answer", id: "1:0")
    queue_for_telegram("hello", id: "m1")

    worker.tick

    assert_equal 1, @store.pending("tg_to_max")
    assert_equal [[101, "Ivan: hello"]], @telegram.sent
  end

  def test_unexpected_error_does_not_crash_worker
    @telegram = FakeTelegram.new(failures: 1, error: RuntimeError.new("boom"))
    queue_for_telegram("hello")

    worker.tick

    assert_equal [1, 1001, "boom"], row_state
  end

  # ---- deleted topic

  def test_deleted_topic_is_recreated
    queue_for_telegram("hello")
    chat_id = @store.rows.first["chat_id"]
    @store.set_topic(chat_id, 55, "Old")
    @telegram = FakeTelegram.new(gone_topics: [55])
    worker = worker()

    worker.tick
    assert_nil @store.chat(chat_id)["tg_topic_id"]

    worker.tick

    assert_equal ["Family"], @telegram.topics
    assert_equal [[101, "Ivan: hello"]], @telegram.sent
    assert_equal 101, @store.chat(chat_id)["tg_topic_id"]
  end

  def test_topics_are_not_recreated_forever
    queue_for_telegram("hello")
    chat_id = @store.rows.first["chat_id"]
    @store.set_topic(chat_id, 55, "Old")
    @telegram = FakeTelegram.new(gone_topics: [55, 101, 102, 103, 104, 105])
    worker = worker()

    10.times do
      @now = @store.rows.first["next_attempt_at"]
      worker.tick
    end

    assert_equal 3, @telegram.topics.size
    assert_equal 1, @store.pending
  end

  # ---- background thread

  def test_background_thread_delivers_after_wake
    worker = Ferry::Worker.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))
    worker.start
    sleep 0.05 # thread go to sleep, there is nothing to do

    queue_for_telegram("hello")
    worker.wake

    deadline = Time.now + 3
    sleep 0.01 until @telegram.sent.any? || Time.now > deadline

    assert_equal [[101, "Ivan: hello"]], @telegram.sent
  ensure
    worker&.stop
  end

  private

  def worker = Ferry::Worker.new(store: @store, telegram: @telegram, max: @max,
                                 logger: Logger.new(nil), clock: -> { @now })

  def row_state
    row = @store.rows.first
    [row["attempts"], row["next_attempt_at"], row["last_error"]]
  end

  def queue_for_telegram(text, id: "m1", chat: -77, author: "Ivan", chat_type: "chat")
    @store.enqueue(max_chat_id: chat, direction: "max_to_tg",
                   items: [[id, { author: author, text: text, chat_type: chat_type }]])
  end

  def queue_for_max(text, id:, chat: -77)
    @store.enqueue(max_chat_id: chat, direction: "tg_to_max", items: [[id, { text: text }]])
  end
end