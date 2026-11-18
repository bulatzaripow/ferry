require "json"

# In-memory copy of Ferry::Store. The same scenarios run against real SQLite in store_test.
class FakeStore
  def initialize
    @chats = {}
    @outbox = []
    @links = []
    @last_id = 0
  end

  def enqueue(max_chat_id:, direction:, items:)
    chat = (@chats[max_chat_id] ||= { "id" => @chats.size + 1, "max_chat_id" => max_chat_id, "tg_topic_id" => nil })
    items.each do |source_id, payload|
      next if @outbox.any? { _1["direction"] == direction && _1["source_id"] == source_id }

      @outbox << { "id" => (@last_id += 1), "chat_id" => chat["id"], "direction" => direction,
                   "source_id" => source_id, "payload" => payload.to_json,
                   "attempts" => 0, "next_attempt_at" => 0, "last_error" => nil }
    end
    chat
  end

  def chat(id) = @chats.values.find { _1["id"] == id }

  def chat_by_topic(topic_id) = @chats.values.find { _1["tg_topic_id"] == topic_id }

  def set_topic(chat_id, topic_id, _title) = chat(chat_id)["tg_topic_id"] = topic_id

  def clear_topic(chat_id) = chat(chat_id)["tg_topic_id"] = nil

  def due(now) = heads.select { _1["next_attempt_at"] <= now }

  def next_due_at = heads.map { _1["next_attempt_at"] }.min

  def link(max_mid, tg_message_id, _now = nil)
    @links << [max_mid, tg_message_id] unless @links.any? { _1.first == max_mid || _1.last == tg_message_id }
  end

  def tg_message_id_for(max_mid) = @links.find { _1.first == max_mid }&.last

  def max_mid_for(tg_message_id) = @links.find { _1.last == tg_message_id }&.first

  def delete(id) = @outbox.reject! { _1["id"] == id }

  def record_failure(id, message, retry_at)
    row = @outbox.find { _1["id"] == id }
    row.merge!("attempts" => row["attempts"] + 1, "last_error" => message, "next_attempt_at" => retry_at)
  end

  # --- helpers for assertions in tests
  def rows = @outbox

  def pending(direction = nil) = @outbox.count { direction.nil? || _1["direction"] == direction }

  private

  def heads
    @outbox.group_by { [_1["chat_id"], _1["direction"]] }.values.map { |rows| rows.min_by { _1["id"] } }.sort_by { _1["id"] }
  end
end