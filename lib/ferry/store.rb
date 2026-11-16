require "json"

module Ferry
  class Store
    HEADS = "o.id = (SELECT MIN(id) FROM outbox WHERE chat_id = o.chat_id AND direction = o.direction)".freeze

    def initialize(db)
      @db = db
      @lock = Mutex.new
    end

    def enqueue(max_chat_id:, direction:, items:)
      chat = nil

      sync do
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
      end

      chat
    end

    def chat(id) = sync { @db.get_first_row("SELECT * FROM chats WHERE id = ?", [id]) }

    def chat_by_topic(topic_id) = sync { @db.get_first_row("SELECT * FROM chats WHERE tg_topic_id = ?", [topic_id]) }

    def set_topic(chat_id, topic_id, title)
      sync { @db.execute("UPDATE chats SET tg_topic_id = ?, title = ? WHERE id = ?", [topic_id, title, chat_id]) }
    end

    def clear_topic(chat_id) = sync { @db.execute("UPDATE chats SET tg_topic_id = NULL WHERE id = ?", [chat_id]) }

    def due(now)
      sync do
        @db.execute("SELECT o.* FROM outbox o WHERE #{HEADS} AND o.next_attempt_at <= ? ORDER BY o.id", [now])
      end
    end

    def next_due_at = sync { @db.get_first_value("SELECT MIN(o.next_attempt_at) FROM outbox o WHERE #{HEADS}") }

    def delete(id) = sync { @db.execute("DELETE FROM outbox WHERE id = ?", [id]) }

    def record_failure(id, message, retry_at)
      sync do
        @db.execute(
          "UPDATE outbox SET attempts = attempts + 1, last_error = ?, next_attempt_at = ? WHERE id = ?",
          [message, retry_at, id]
        )
      end
    end

    private

    def sync(&) = @lock.synchronize(&)
  end
end