require "json"
require "openssl"
require "timeout"

module Ferry
  class ApiError < StandardError
    TRANSIENT = [
      SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError
    ].freeze

    attr_reader :code, :retry_after

    def initialize(message, code: nil, retry_after: nil)
      super(message)
      @code = code
      @retry_after = retry_after
    end

    def retryable? = code.nil? || code == 429 || code >= 500
  end
end