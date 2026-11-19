require "json"

module Ferry
  class Store
    # The oldest message of every queue (chat + direction)
    HEADS = "o.id = (SELECT MIN(id) FROM outbox WHERE chat_id = o.chat_id AND direction = o.direction)".freeze
    LINK_TTL = 30 * 24 * 3600 # replies to messages older than this are sent without the reply mark

    def initialize(db)
      @db = db
      @lock = Mutex.new
    end

    def enqueue(max_chat_id:, direction:, items:, due_at: 0)
      chat = nil

      sync do
        @db.transaction do
          @db.execute("INSERT INTO chats (max_chat_id) VALUES (?) ON CONFLICT (max_chat_id) DO NOTHING", [max_chat_id])
          chat = @db.get_first_row("SELECT * FROM chats WHERE max_chat_id = ?", [max_chat_id])

          items.each do |source_id, payload, group_key|
            @db.execute(
              "INSERT INTO outbox (chat_id, direction, source_id, payload, group_key, next_attempt_at) " \
              "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (direction, source_id) DO NOTHING",
              [chat["id"], direction, source_id, payload.to_json, group_key, due_at]
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

    def group(row)
      return [row] unless row["group_key"]

      sync do
        @db.execute("SELECT * FROM outbox WHERE chat_id = ? AND direction = ? AND group_key = ? ORDER BY id",
                    [row["chat_id"], row["direction"], row["group_key"]])
      end
    end

    def next_due_at = sync { @db.get_first_value("SELECT MIN(o.next_attempt_at) FROM outbox o WHERE #{HEADS}") }

    def delete(id) = sync { @db.execute("DELETE FROM outbox WHERE id = ?", [id]) }

    # Remembers that two messages (one in each messenger) are the same one; also drops old links
    def link(max_mid, tg_message_id, now = Time.now.to_i)
      sync do
        @db.execute("INSERT INTO links (max_mid, tg_message_id, created_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                    [max_mid, tg_message_id, now])
        @db.execute("DELETE FROM links WHERE created_at < ?", [now - LINK_TTL])
      end
    end

    def tg_message_id_for(max_mid) = sync { @db.get_first_value("SELECT tg_message_id FROM links WHERE max_mid = ?", [max_mid]) }

    def max_mid_for(tg_message_id) = sync { @db.get_first_value("SELECT max_mid FROM links WHERE tg_message_id = ?", [tg_message_id]) }

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