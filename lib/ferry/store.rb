require "json"

module Ferry
  class Store
    def initialize(db) = @db = db

    def enqueue(max_chat_id:, direction:, items:)
      chat = nil

      @db.transaction do
        @db.execute("INSERT INTO chats (max_chat_id) VALUES (?) ON CONFLICT (max_chat_id) DO NOTHING", [max_chat_id])
        chat = @db.get_first_row("SELECT * FROM chats WHERE max_chat_id = ?", [max_chat_id])

        items.each do |source_id, payload|
          @db.execute(
            "INSERT INTO outbox (chat_id, direction, source_id, payload) VALUES (?, ?, ?, ?) " \
            "ON CONFLICT (direction, source_id) DO NOTHING",
            [chat["id"], direction, source_id, payload.to_json]
          )
        end
      end

      chat
    end

    def chat(id) = @db.get_first_row("SELECT * FROM chats WHERE id = ?", [id])

    def chat_by_topic(topic_id) = @db.get_first_row("SELECT * FROM chats WHERE tg_topic_id = ?", [topic_id])

    def set_topic(chat_id, topic_id, title)
      @db.execute("UPDATE chats SET tg_topic_id = ?, title = ? WHERE id = ?", [topic_id, title, chat_id])
    end

    def next_in_queue(chat_id, direction)
      @db.get_first_row(
        "SELECT * FROM outbox WHERE chat_id = ? AND direction = ? ORDER BY id LIMIT 1", [chat_id, direction]
      )
    end

    def delete(id) = @db.execute("DELETE FROM outbox WHERE id = ?", [id])

    def record_failure(id, message)
      @db.execute("UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE id = ?", [message, id])
    end
  end
end