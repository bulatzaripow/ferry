require "json"
require "logger"

require_relative "api_error"

module Ferry
  class Worker
    GAP = 0.5      # pause between rounds (2 message per second for Max)
    MAX_IDLE = 60  # how much sleep

    def initialize(store:, telegram:, max:, logger: Logger.new($stdout), clock: -> { Time.now.to_i })
      @store = store
      @telegram = telegram
      @max = max
      @logger = logger
      @clock = clock
      @wakeup = Thread::Queue.new
    end

    def start
      @thread = Thread.new { run }
    end

    def stop = @thread&.kill

    def wake = @wakeup << :wake

    def tick
      rows = @store.due(@clock.call)
      rows.each { attempt(_1) }
      rows.size
    end

    private

    def run
      loop do
        if tick.positive?
          sleep GAP
        else
          @wakeup.pop(timeout: idle_timeout)
          @wakeup.clear
        end
      rescue StandardError => e
        @logger.error("worker: #{e.class}: #{e.message}")
        sleep 5
      end
    end

    def idle_timeout
      next_at = @store.next_due_at
      next_at ? (next_at - @clock.call).clamp(1, MAX_IDLE) : MAX_IDLE
    end

    def attempt(row)
      deliver(row)
      @store.delete(row["id"])
      @logger.info("#{row["direction"]}: delivered #{row["source_id"]}")
    rescue StandardError => e
      retry_later(row, e)
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

    def retry_later(row, error)
      recreate_topic = topic_gone?(error) && row["attempts"] < 3
      @store.clear_topic(row["chat_id"]) if recreate_topic

      delay = recreate_topic ? 0 : backoff(row, error)
      @store.record_failure(row["id"], error.message, @clock.call + delay)
      @logger.public_send(log_level(error),
                          "#{row["direction"]}: #{row["source_id"]} not delivered, retry in #{delay}s (#{error.class}: #{error.message})")
    end

    def backoff(row, error)
      (error.retry_after if error.is_a?(ApiError)) || 2**row["attempts"].clamp(0, 8)
    end

    def topic_gone?(error) = error.is_a?(ApiError) && error.code == 400 && error.message.match?(/thread not found/i)

    def log_level(error) = error.is_a?(ApiError) && error.retryable? ? :warn : :error
  end
end