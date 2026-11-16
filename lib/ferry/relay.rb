require "json"
require "logger"

require_relative "api_error"

module Ferry
  class Relay
    CHAT_TYPES = %w[dialog chat].freeze

    def initialize(store:, telegram:, max:, logger: Logger.new($stdout))
      @store = store
      @telegram = telegram
      @max = max
      @logger = logger
      @lock = Mutex.new
    end

    def handle_max_update(update)
      return unless update["update_type"] == "message_created"

      message = update["message"]
      if (reason = skip_reason(message))
        @logger.info("max: message skipped (#{reason})")
        return
      end

      @lock.synchronize do
        chat = @store.enqueue(
          max_chat_id: message.dig("recipient", "chat_id"),
          direction: "max_to_tg",
          source_id: message.dig("body", "mid"),
          payload: {
            author: author_name(message["sender"]),
            text: message.dig("body", "text"),
            chat_type: message.dig("recipient", "chat_type")
          }
        )
        drain(chat["id"], "max_to_tg")
      end
    end

    private

    def skip_reason(message)
      sender = message["sender"]

      case
      when !CHAT_TYPES.include?(message.dig("recipient", "chat_type")) then "unsupported chat type"
      when message.dig("recipient", "chat_id").nil? then "no chat id"
      when sender.nil? || sender["is_bot"] then "sent by a bot or a channel"
      when message.dig("body", "text").to_s.empty? then "no text"
      end
    end

    def author_name(sender)
      name = sender.values_at("first_name", "last_name").join(" ").strip
      name.empty? ? (sender["username"] || "id#{sender["user_id"]}") : name
    end

    def drain(chat_id, direction)
      while (row = @store.next_in_queue(chat_id, direction))
        deliver(row)
        @store.delete(row["id"])
        @logger.info("#{direction}: delivered #{row["source_id"]}")
      end
    rescue ApiError => e
      @store.record_failure(row["id"], e.message)
      @logger.warn("#{direction}: #{row["source_id"]} not delivered, stays in queue (#{e.message})")
    end

    def deliver(row)
      chat = @store.chat(row["chat_id"])
      payload = JSON.parse(row["payload"])
      topic_id = chat["tg_topic_id"] || create_topic(chat, payload)

      @telegram.send_message(topic_id: topic_id, text: "#{payload["author"]}: #{payload["text"]}")
    end

    def create_topic(chat, payload)
      name = payload["chat_type"] == "dialog" ? payload["author"] : @max.get_chat(chat["max_chat_id"])["title"]
      name = "Max #{chat["max_chat_id"]}" if name.to_s.strip.empty?
      name = name[0, 128]

      topic_id = @telegram.create_topic(name)
      @store.set_topic(chat["id"], topic_id, name)
      topic_id
    end
  end
end