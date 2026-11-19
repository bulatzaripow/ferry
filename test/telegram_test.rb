require_relative "test_helper"
require_relative "fake_http"
require "ferry/telegram"

class TelegramTest < Minitest::Test
  def test_send_message
    http = FakeHttp.new(ok("message_id" => 7))

    result = telegram(http).send_message(topic_id: 12, text: "Ivan: hello")

    assert_equal({ "message_id" => 7 }, result)
    assert_equal "https://api.telegram.org/bottoken/sendMessage", http.requests.first.url
    assert_equal({ "chat_id" => -100, "message_thread_id" => 12, "text" => "Ivan: hello", "parse_mode" => "HTML" }, http.requests.first.json)
  end

  def test_create_topic_returns_topic_id
    http = FakeHttp.new(ok("message_thread_id" => 55, "name" => "Family"))

    assert_equal 55, telegram(http).create_topic("Family")
    assert_equal({ "chat_id" => -100, "name" => "Family" }, http.requests.first.json)
  end

  def test_rename_topic
    http = FakeHttp.new(ok(true))

    telegram(http).rename_topic(55, "New name")

    assert_equal "https://api.telegram.org/bottoken/editForumTopic", http.requests.first.url
    assert_equal({ "chat_id" => -100, "message_thread_id" => 55, "name" => "New name" }, http.requests.first.json)
  end

  def test_set_webhook
    http = FakeHttp.new(ok(true))

    telegram(http).set_webhook(url: "https://example.com/telegram", secret: "s3cret")

    assert_equal "https://api.telegram.org/bottoken/setWebhook", http.requests.first.url
    assert_equal({ "url" => "https://example.com/telegram", "secret_token" => "s3cret",
                   "allowed_updates" => ["message"] }, http.requests.first.json)
  end

  def test_reply_is_sent_as_reply_parameters
    http = FakeHttp.new(ok({}))

    telegram(http).send_message(topic_id: 12, text: "answer", reply_to: 77)

    assert_equal({ "message_id" => 77, "allow_sending_without_reply" => true }, http.requests.first.json["reply_parameters"])
  end

  # ---- files

  def test_send_photo_is_multipart_with_caption
    http = FakeHttp.new(ok("message_id" => 1))

    telegram(http).send_media(topic_id: 12, kind: "image", io: StringIO.new("PHOTO-BYTES"), filename: "a.jpg", caption: "Ivan: look")

    request = http.requests.first
    assert_equal "https://api.telegram.org/bottoken/sendPhoto", request.url
    assert_match(%r{Content-Type: multipart/form-data}, request.wire)
    assert_match(/name="chat_id"\r\n\r\n-100\r\n/, request.wire)
    assert_match(/name="message_thread_id"\r\n\r\n12\r\n/, request.wire)
    assert_match(/name="caption"\r\n\r\nIvan: look\r\n/, request.wire)
    assert_match(/name="parse_mode"\r\n\r\nHTML\r\n/, request.wire)
    assert_match(/name="photo"; filename="a.jpg"\r\n.*\r\n\r\nPHOTO-BYTES\r\n/m, request.wire)
  end

  def test_send_media_picks_method_and_field_by_kind
    {
      "video" => %w[sendVideo video], "voice" => %w[sendVoice voice], "audio" => %w[sendAudio audio],
      "file" => %w[sendDocument document], "sticker" => %w[sendSticker sticker]
    }.each do |kind, (method, field)|
      http = FakeHttp.new(ok({}))

      telegram(http).send_media(topic_id: 1, kind: kind, io: StringIO.new("x"), filename: "f.bin", caption: nil)

      assert http.requests.first.url.end_with?("/#{method}"), kind
      assert_match(/name="#{field}"; filename="f.bin"/, http.requests.first.wire, kind)
      refute_match(/name="caption"/, http.requests.first.wire, kind)
    end
  end

  def test_reply_to_a_file_is_a_json_form_field
    http = FakeHttp.new(ok({}))

    telegram(http).send_media(topic_id: 1, kind: "file", io: StringIO.new("x"), filename: "r.pdf", reply_to: 77)

    assert_match(/name="reply_parameters"\r\n\r\n\{"message_id":77,"allow_sending_without_reply":true\}\r\n/, http.requests.first.wire)
  end

  def test_album_is_one_multipart_request_with_caption_on_the_first_item
    http = FakeHttp.new(ok([{ "message_id" => 1 }, { "message_id" => 2 }]))
    items = [{ kind: "image", io: StringIO.new("ONE"), filename: "a.jpg" }, { kind: "video", io: StringIO.new("TWO"), filename: "b.mp4" }]

    result = telegram(http).send_media_group(topic_id: 12, items: items, caption: "<b>Ivan</b>", reply_to: 77)

    assert_equal 2, result.size
    wire = http.requests.first.wire
    assert_equal "https://api.telegram.org/bottoken/sendMediaGroup", http.requests.first.url
    assert_match(/name="file0"; filename="a.jpg"\r\n.*\r\n\r\nONE\r\n/m, wire)
    assert_match(/name="file1"; filename="b.mp4"\r\n.*\r\n\r\nTWO\r\n/m, wire)
    assert_match(/name="reply_parameters"/, wire)
    media = JSON.parse(wire[/name="media"\r\n\r\n(.*?)\r\n/, 1])
    assert_equal [{ "type" => "photo", "media" => "attach://file0", "caption" => "<b>Ivan</b>", "parse_mode" => "HTML" },
                  { "type" => "video", "media" => "attach://file1", "supports_streaming" => true }], media
  end

  def test_album_types_follow_the_kinds
    http = FakeHttp.new(ok([]))
    items = [{ kind: "file", io: StringIO.new("x"), filename: "a.pdf" }, { kind: "file", io: StringIO.new("y"), filename: "b.pdf" }]

    telegram(http).send_media_group(topic_id: 1, items: items)

    media = JSON.parse(http.requests.first.wire[/name="media"\r\n\r\n(.*?)\r\n/, 1])
    assert_equal %w[document document], media.map { _1["type"] }
    refute media.first.key?("caption")
  end

  def test_video_is_sent_for_streaming
    http = FakeHttp.new(ok({}))

    telegram(http).send_media(topic_id: 1, kind: "video", io: StringIO.new("x"), filename: "v.mp4")

    assert_match(/name="supports_streaming"\r\n\r\ntrue\r\n/, http.requests.first.wire)
  end

  def test_send_location_and_contact
    http = FakeHttp.new(ok({}), ok({}))
    client = telegram(http)

    client.send_location(topic_id: 3, latitude: 55.75, longitude: 37.61)
    client.send_contact(topic_id: 3, phone: "+79990001122", name: "Ivan")

    assert_equal({ "chat_id" => -100, "message_thread_id" => 3, "latitude" => 55.75, "longitude" => 37.61 },
                 http.requests[0].json)
    assert_equal({ "chat_id" => -100, "message_thread_id" => 3, "phone_number" => "+79990001122", "first_name" => "Ivan" },
                 http.requests[1].json)
  end

  def test_download_asks_for_path_then_fetches_file
    url = "https://api.telegram.org/file/bottoken/photos/a.jpg"
    http = FakeHttp.new(ok("file_path" => "photos/a.jpg"), files: { url => "PHOTO-BYTES" })
    io = StringIO.new

    telegram(http).download("FILE-ID", io)

    assert_equal "https://api.telegram.org/bottoken/getFile", http.requests.first.url
    assert_equal({ "file_id" => "FILE-ID" }, http.requests.first.json)
    assert_equal [url], http.downloaded
    assert_equal "PHOTO-BYTES", io.string
  end

  # ---- errors

  def test_rate_limit_is_retryable_and_has_retry_after
    http = FakeHttp.new(failure(429, "Too Many Requests: retry after 5", retry_after: 5))

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert_equal 429, error.code
    assert_equal 5, error.retry_after
    assert error.retryable?
  end

  def test_bad_request_is_not_retryable
    http = FakeHttp.new(failure(400, "Bad Request: message thread not found"))

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert_equal 400, error.code
    refute error.retryable?
    assert error.topic_gone?
  end

  def test_server_error_is_retryable
    http = FakeHttp.new(failure(502, "Bad Gateway"))

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert error.retryable?
  end

  def test_non_json_reply_is_retryable
    http = FakeHttp.new([502, "<html>502 Bad Gateway</html>"])

    error = assert_raises(Ferry::ApiError) { telegram(http).send_message(topic_id: 1, text: "x") }

    assert error.retryable?
  end

  private

  def telegram(http) = Ferry::Telegram.new("token", -100, http: http)

  def ok(result) = [200, { ok: true, result: result }.to_json]

  def failure(code, description, **parameters)
    [code, { ok: false, error_code: code, description: description, parameters: parameters }.to_json]
  end
end