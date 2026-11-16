require "json"
require "openssl"
require "timeout"

module Ferry
  class ApiError < StandardError
    TRANSIENT = [
      SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError
    ].freeze

    attr_reader :code, :retry_after

    def initialize(message, code: nil, retry_after: nil, transient: false)
      super(message)
      @code = code
      @retry_after = retry_after
      @transient = transient
    end

    # Retrying may help: network trouble, rate limits, server errors, "file is not processed yet"
    def retryable? = @transient || code.nil? || code == 429 || code >= 500

    # Retrying will not help because the message or file itself is not acceptable.
    # 401 and 403 are excluded: a human fixes those (token, bot rights).
    def permanent? = !retryable? && ![401, 403].include?(code)

    # The topic was deleted by hand in Telegram
    def topic_gone? = code == 400 && message.match?(/thread not found/i)
  end
end