require "logger"

module Ferry
  class Relay
    CHAT_TYPES = %w[dialog chat].freeze
    PART = /.{1,3800}/m # max message chunk for max and telegram

    def initialize(store:, worker:, owner_id:, group_id:, logger: Logger.new($stdout))
      @store = store
      @worker = worker
      @owner_id = owner_id
      @group_id = group_id
      @logger = logger
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

      queue(message.dig("recipient", "chat_id"), "max_to_tg", items)
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
      queue(chat["max_chat_id"], "tg_to_max", items)
    end

    private

    def queue(max_chat_id, direction, items)
      @store.enqueue(max_chat_id: max_chat_id, direction: direction, items: items)
      @logger.info("#{direction}: queued #{items.map(&:first).join(", ")}")
      @worker.wake
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
  end
end