require "json"
require "logger"

require_relative "api_error"

module Ferry
  class Relay
    CHAT_TYPES = %w[dialog chat].freeze
    PART = /.{1,3800}/m

    def initialize(store:, telegram:, max:, owner_id:, group_id:, logger: Logger.new($stdout))
      @store = store
      @telegram = telegram
      @max = max
      @owner_id = owner_id
      @group_id = group_id
      @logger = logger
      @lock = Mutex.new
    end

    def handle_max_update(update)
      return unless update["update_type"] == "message_created"

      message = update["message"]
      if (reason = max_skip_reason(message))
        @logger.info("max: message skipped (#{reason})")
        return
      end

      author = author_name(message["sender"])
      chat_type = message.dig("recipient", "chat_type")
      items = split(message.dig("body", "mid"), message.dig("body", "text")) do |part|
        { author: author, text: part, chat_type: chat_type }
      end

      enqueue_and_drain(message.dig("recipient", "chat_id"), "max_to_tg", items)
    end

    def handle_telegram_update(update)
      message = update["message"]
      return unless message

      if (reason = telegram_skip_reason(message))
        @logger.info("telegram: message skipped (#{reason})")
        return
      end

      unless (chat = @store.chat_by_topic(message["message_thread_id"]))
        @logger.info("telegram: message skipped (unknown topic #{message["message_thread_id"]})")
        return
      end

      items = split(message["message_id"], message["text"]) { |part| { text: part } }
      enqueue_and_drain(chat["max_chat_id"], "tg_to_max", items)
    end

    private

    def enqueue_and_drain(max_chat_id, direction, items)
      @lock.synchronize do
        chat = @store.enqueue(max_chat_id: max_chat_id, direction: direction, items: items)
        drain(chat["id"], direction)
      end
    end

    def split(source_id, text)
      text.scan(PART).each_with_index.map { |part, i| ["#{source_id}:#{i}", yield(part)] }
    end

    def max_skip_reason(message)
      sender = message["sender"]

      case
      when !CHAT_TYPES.include?(message.dig("recipient", "chat_type")) then "unsupported chat type"
      when message.dig("recipient", "chat_id").nil? then "no chat id"
      when sender.nil? || sender["is_bot"] then "sent by a bot or a channel"
      when message.dig("body", "text").to_s.empty? then "no text"
      end
    end

    def telegram_skip_reason(message)
      case
      when message.dig("from", "id") != @owner_id || message.dig("chat", "id") != @group_id then "not from the owner in the group"
      when message["message_thread_id"].nil? then "not in a topic"
      when message["text"].to_s.empty? then "no text"
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

      case row["direction"]
      when "max_to_tg" then deliver_to_telegram(chat, payload)
      when "tg_to_max" then @max.send_message(chat_id: chat["max_chat_id"], text: payload["text"])
      end
    end

    def deliver_to_telegram(chat, payload)
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