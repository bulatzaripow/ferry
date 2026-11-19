require "logger"

require_relative "api_error"

module Ferry
  class Worker
    GAP = 0.5      # pause between rounds: at most 2 messages per second to one chat (Max limit)
    MAX_IDLE = 60  # longest sleep when there is nothing to do

    def initialize(store:, courier:, logger: Logger.new($stdout), clock: -> { Time.now.to_i })
      @store = store
      @courier = courier
      @logger = logger
      @clock = clock
      @wakeup = Thread::Queue.new
    end

    def start
      @thread = Thread.new { run }
    end

    def stop = @thread&.kill

    def wake = @wakeup << :wake

    # One round: one message from every queue that is due
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
      rows = @store.group(row) # one row, or all the rows of an album
      @courier.deliver(row, rows)
      rows.each { @store.delete(_1["id"]) }
      @logger.info("#{row["direction"]}: delivered #{rows.map { _1["source_id"] }.join(", ")}")
    rescue StandardError => e
      retry_later(row, e)
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

    def topic_gone?(error) = error.is_a?(ApiError) && error.topic_gone?

    def log_level(error) = error.is_a?(ApiError) && error.retryable? ? :warn : :error
  end
end