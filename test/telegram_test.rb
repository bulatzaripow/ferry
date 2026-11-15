require_relative "test_helper"
require "ferry/telegram"

class TelegramTest < Minitest::Test
  class FakeHTTP
    Response = Struct.new(:body)
    attr_reader :requests

    def initialize(*replies)
      @replies = replies
      @requests = []
    end

    def post(uri, data, _headers)
      @requests << { url: uri.to_s, body: JSON.parse(data) }
      reply = @replies.shift
      raise reply if reply.is_a?(Exception)

      Response.new(reply)
    end
  end

  def test_send_message
    http = FakeHTTP.new(ok("message_id" => 7))

    result = telegram(http).send_message(topic_id: 12, text: "Иван: привет")

    assert_equal({ "message_id" => 7 }, result)
    assert_equal "https://api.telegram.org/bottoken/sendMessage", http.requests.first[:url]
    assert_equal({ "chat_id" => -100, "message_thread_id" => 12, "text" => "Иван: привет" }, http.requests.first[:body])
  end

  def test_create_topic_returns_topic_id
    http = FakeHTTP.new(ok("message_thread_id" => 55, "name" => "Семья"))

    assert_equal 55, telegram(http).create_topic("Семья")
    assert_equal({ "chat_id" => -100, "name" => "Семья" }, http.requests.first[:body])
  end

  def test_rename_topic
    http = FakeHTTP.new(ok(true))

    telegram(http).rename_topic(55, "Новое имя")

    assert_equal "https://api.telegram.org/bottoken/editForumTopic", http.requests.first[:url]
    assert_equal({ "chat_id" => -100, "message_thread_id" => 55, "name" => "Новое имя" }, http.requests.first[:body])
  end

  def test_rate_limit_is_retryable_and_has_retry_after
    http = FakeHTTP.new(failure(429, "Too Many Requests: retry after 5", retry_after: 5))

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert_equal 429, error.code
    assert_equal 5, error.retry_after
    assert error.retryable?
  end

  def test_bad_request_is_not_retryable
    http = FakeHTTP.new(failure(400, "Bad Request: message thread not found"))

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert_equal 400, error.code
    refute error.retryable?
  end

  def test_server_error_is_retryable
    http = FakeHTTP.new(failure(502, "Bad Gateway"))

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert error.retryable?
  end

  def test_network_error_is_retryable
    http = FakeHTTP.new(Errno::ECONNREFUSED.new)

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert_nil error.code
    assert error.retryable?
  end

  def test_non_json_reply_is_retryable
    http = FakeHTTP.new("<html>502 Bad Gateway</html>")

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert error.retryable?
  end

  private

  def telegram(http) = Ferry::Telegram.new("token", -100, http: http)

  def ok(result) = { ok: true, result: result }.to_json

  def failure(code, description, **parameters)
    { ok: false, error_code: code, description: description, parameters: parameters }.to_json
  end
end