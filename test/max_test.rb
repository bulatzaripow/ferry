require_relative "test_helper"
require "tmpdir"
require "ferry/max"

class MaxTest < Minitest::Test
  class FakeHTTP
    Response = Struct.new(:code, :body)
    attr_reader :requests, :options

    def initialize(*replies)
      @replies = replies
      @requests = []
    end

    def start(_host, _port, **options)
      @options = options
      yield self
    end

    def request(req)
      @requests << { method: req.method, path: req.path, token: req["Authorization"],
                     body: req.body && JSON.parse(req.body) }
      reply = @replies.shift
      raise reply if reply.is_a?(Exception)

      Response.new(*reply)
    end
  end

  def test_send_message
    http = FakeHTTP.new([200, { message: { body: { mid: "m1" } } }.to_json])

    result = max(http).send_message(chat_id: -77, text: "Иван: привет")

    assert_equal "m1", result.dig("message", "body", "mid")
    assert_equal({ method: "POST", path: "/messages?chat_id=-77", token: "max-token", body: { "text" => "Иван: привет" } },
                 http.requests.first)
  end

  def test_get_chat
    http = FakeHTTP.new([200, { chat_id: -77, title: "Семья" }.to_json])

    chat = max(http).get_chat(-77)

    assert_equal "Семья", chat["title"]
    assert_equal({ method: "GET", path: "/chats/-77", token: "max-token", body: nil }, http.requests.first)
  end

  def test_me
    http = FakeHTTP.new([200, { user_id: 1, is_bot: true }.to_json])

    assert_equal true, max(http).me["is_bot"]
    assert_equal "/me", http.requests.first[:path]
  end

  def test_subscribe
    http = FakeHTTP.new([200, { success: true }.to_json])

    max(http).subscribe(url: "https://example.com/max", secret: "s3cret")

    assert_equal "/subscriptions", http.requests.first[:path]
    assert_equal({ "url" => "https://example.com/max", "update_types" => %w[message_created chat_title_changed],
                   "secret" => "s3cret" }, http.requests.first[:body])
  end

  def test_subscribe_failure_raises
    http = FakeHTTP.new([200, { success: false, message: "url is unreachable" }.to_json])

    error = assert_raises(Ferry::ApiError) { max(http).subscribe(url: "https://example.com/max", secret: "s3cret") }

    assert_match(/url is unreachable/, error.message)
    refute error.retryable?
  end

  def test_unauthorized_is_not_retryable
    http = FakeHTTP.new([401, { code: "verify.token", message: "Invalid access_token" }.to_json])

    error = assert_raises(Ferry::ApiError) { max(http).me }

    assert_equal 401, error.code
    refute error.retryable?
  end

  def test_rate_limit_and_server_error_are_retryable
    http = FakeHTTP.new([429, "{}"], [503, "Service Unavailable"])

    [429, 503].each do |code|
      error = assert_raises(Ferry::ApiError) { max(http).send_message(chat_id: 1, text: "x") }

      assert_equal code, error.code
      assert error.retryable?
    end
  end

  def test_network_error_is_retryable
    http = FakeHTTP.new(Errno::ECONNRESET.new)

    error = assert_raises(Ferry::ApiError) { max(http).me }

    assert_nil error.code
    assert error.retryable?
  end

  def test_uses_tls_with_cert_store
    http = FakeHTTP.new([200, "{}"])

    max(http).me

    assert_equal true, http.options[:use_ssl]
    assert_kind_of OpenSSL::X509::Store, http.options[:cert_store]
  end

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