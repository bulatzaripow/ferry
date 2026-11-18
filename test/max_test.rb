require_relative "test_helper"
require_relative "fake_http"
require "tmpdir"
require "ferry/max"

class MaxTest < Minitest::Test
  def test_send_message
    http = FakeHttp.new(reply(message: { body: { mid: "m1" } }))

    result = max(http).send_message(chat_id: -77, text: "Ivan: hello")

    assert_equal "m1", result.dig("message", "body", "mid")
    request = http.requests.first
    assert_equal ["POST", "https://platform-api2.max.ru/messages?chat_id=-77", "max-token"],
                 [request.method, request.url, request.token]
    assert_equal({ "text" => "Ivan: hello" }, request.json)
  end

  def test_send_message_with_attachment_and_without_text
    http = FakeHttp.new(reply({}))
    attachment = { type: "image", payload: { token: "T1" } }

    max(http).send_message(chat_id: 1, text: "", attachments: [attachment])

    assert_equal({ "attachments" => [{ "type" => "image", "payload" => { "token" => "T1" } }] }, http.requests.first.json)
  end

  def test_reply_is_sent_as_link
    http = FakeHttp.new(reply({}))

    max(http).send_message(chat_id: 1, text: "answer", reply_to: "mid.42")

    assert_equal({ "text" => "answer", "link" => { "type" => "reply", "mid" => "mid.42" } }, http.requests.first.json)
  end

  def test_get_chat
    http = FakeHttp.new(reply(chat_id: -77, title: "Family"))

    chat = max(http).get_chat(-77)

    assert_equal "Family", chat["title"]
    assert_equal ["GET", "https://platform-api2.max.ru/chats/-77", "max-token", nil],
                 http.requests.first.to_a.first(4)
  end

  def test_me
    http = FakeHttp.new(reply(user_id: 1, is_bot: true))

    assert_equal true, max(http).me["is_bot"]
    assert_equal "/me", http.requests.first.path
  end

  def test_subscribe
    http = FakeHttp.new(reply(success: true))

    max(http).subscribe(url: "https://example.com/max", secret: "s3cret")

    assert_equal "/subscriptions", http.requests.first.path
    assert_equal({ "url" => "https://example.com/max", "update_types" => %w[message_created chat_title_changed],
                   "secret" => "s3cret" }, http.requests.first.json)
  end

  def test_subscribe_failure_raises
    http = FakeHttp.new(reply(success: false, message: "url is unreachable"))

    error = assert_raises(Ferry::ApiError) { max(http).subscribe(url: "https://example.com/max", secret: "s3cret") }

    assert_match(/url is unreachable/, error.message)
    refute error.retryable?
  end

  # ---- uploads

  def test_upload_image_takes_token_from_photos
    http = FakeHttp.new(reply(url: "https://upload.example/u1"), reply(photos: { "id1" => { token: "PHOTO-TOKEN" } }))

    attachment = max(http).upload("image", StringIO.new("IMAGE-BYTES"), "a.jpg")

    assert_equal({ type: "image", payload: { token: "PHOTO-TOKEN" } }, attachment)
    slot, upload = http.requests
    assert_equal "https://platform-api2.max.ru/uploads?type=image", slot.url
    assert_equal "https://upload.example/u1", upload.url
    assert_nil upload.token, "the Max token must not be sent to the upload host"
    assert_match(/name="data"; filename="a.jpg"\r\n.*\r\n\r\nIMAGE-BYTES\r\n/m, upload.wire)
  end

  def test_upload_video_takes_token_from_the_upload_slot
    http = FakeHttp.new(reply(url: "https://upload.example/u2", token: "VIDEO-TOKEN"), [200, "<retval>1</retval>"])

    attachment = max(http).upload("video", StringIO.new("x"), "v.mp4")

    assert_equal({ type: "video", payload: { token: "VIDEO-TOKEN" } }, attachment)
  end

  def test_upload_file_takes_token_from_the_upload_reply
    http = FakeHttp.new(reply(url: "https://upload.example/u3"), reply(fileId: 5, token: "FILE-TOKEN"))

    assert_equal({ type: "file", payload: { token: "FILE-TOKEN" } }, max(http).upload("file", StringIO.new("x"), "r.pdf"))
  end

  def test_voice_and_audio_are_uploaded_as_audio
    %w[voice audio].each do |kind|
      http = FakeHttp.new(reply(url: "https://upload.example/u4", token: "AUDIO-TOKEN"), [200, "<retval>1</retval>"])

      attachment = max(http).upload(kind, StringIO.new("x"), "a.m4a")

      assert_equal "audio", attachment[:type]
      assert_equal "https://platform-api2.max.ru/uploads?type=audio", http.requests.first.url
    end
  end

  def test_upload_without_token_raises
    http = FakeHttp.new(reply(url: "https://upload.example/u5"), [200, "<retval>1</retval>"])

    assert_raises(Ferry::ApiError) { max(http).upload("image", StringIO.new("x"), "a.jpg") }
  end

  def test_upload_of_unknown_kind_raises
    assert_raises(KeyError) { max(FakeHttp.new).upload("sticker", StringIO.new("x"), "s.webp") }
  end

  def test_upload_failure_on_the_upload_host_raises_api_error
    http = FakeHttp.new(reply(url: "https://upload.example/u6"), [415, "Unsupported Media Type"])

    error = assert_raises(Ferry::ApiError) { max(http).upload("file", StringIO.new("x"), "r.xyz") }

    assert_equal 415, error.code
    assert error.permanent?
  end

  def test_download_is_delegated_to_http
    http = FakeHttp.new(files: { "https://cdn.example/a.jpg" => "IMAGE-BYTES" })
    io = StringIO.new

    max(http).download("https://cdn.example/a.jpg", io)

    assert_equal "IMAGE-BYTES", io.string
  end

  # ---- errors

  def test_unauthorized_is_not_retryable_and_not_permanent
    http = FakeHttp.new([401, { code: "verify.token", message: "Invalid access_token" }.to_json])

    error = assert_raises(Ferry::ApiError) { max(http).me }

    assert_equal 401, error.code
    refute error.retryable?
    refute error.permanent?
  end

  def test_rate_limit_and_server_error_are_retryable
    http = FakeHttp.new([429, "{}"], [503, "Service Unavailable"])

    [429, 503].each do |code|
      error = assert_raises(Ferry::ApiError) { max(http).send_message(chat_id: 1, text: "x") }

      assert_equal code, error.code
      assert error.retryable?
    end
  end

  def test_attachment_not_ready_is_retryable
    http = FakeHttp.new([400, { code: "attachment.not.ready", message: "Key: errors.process.attachment.file.not.processed" }.to_json])

    error = assert_raises(Ferry::ApiError) { max(http).send_message(chat_id: 1, text: "x", attachments: []) }

    assert_equal 400, error.code
    assert error.retryable?
  end

  def test_other_bad_request_is_permanent
    http = FakeHttp.new([400, { code: "proto.payload", message: "bad payload" }.to_json])

    error = assert_raises(Ferry::ApiError) { max(http).send_message(chat_id: 1, text: "x") }

    assert error.permanent?
  end

  def test_network_error_is_passed_through
    http = FakeHttp.new(Ferry::ApiError.new("platform-api2.max.ru: Errno::ECONNRESET"))

    error = assert_raises(Ferry::ApiError) { max(http).me }

    assert_nil error.code
    assert error.retryable?
  end

  # ---- certificates

  def test_cert_store_trusts_certificates_from_dir
    cert = self_signed_ca

    Dir.mktmpdir do |dir|
      refute Ferry::Max.cert_store(dir).verify(cert)

      File.write(File.join(dir, "root.crt"), cert.to_pem)

      assert Ferry::Max.cert_store(dir).verify(cert)
    end
  end

  private

  def max(http) = Ferry::Max.new("max-token", certs_dir: "no-such-dir", http: http)

  def reply(body) = [200, body.to_json]

  def self_signed_ca
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=Test Root CA")
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert.add_extension(OpenSSL::X509::ExtensionFactory.new(cert, cert).create_extension("basicConstraints", "CA:TRUE", true))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    cert
  end
end