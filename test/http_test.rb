require_relative "test_helper"
require "stringio"
require "ferry/http"

class HttpTest < Minitest::Test
  # A response that is a real Net::HTTPSuccess and streams its body in two chunks
  class Ok < Net::HTTPOK
    def initialize(body)
      super("1.1", "200", "OK")
      @chunks = [body[0, 3], body[3..]]
    end

    def read_body = @chunks.each { yield _1 }
  end

  class FakeNet
    attr_reader :host, :options, :requested

    def initialize(*responses)
      @responses = responses
      @requested = []
    end

    def start(host, _port, **options)
      @host = host
      @options = options
      yield self
    end

    def request(req)
      @requested << req.uri.to_s
      response = @responses.shift
      raise response if response.is_a?(Exception)

      yield response if block_given?
      response
    end
  end

  def test_request_uses_tls_and_timeouts
    net = FakeNet.new(Ok.new("body"))

    Ferry::Http.new(net: net).request(Net::HTTP::Get.new(URI("https://example.com/path")))

    assert_equal "example.com", net.host
    assert_equal true, net.options[:use_ssl]
    assert_equal 10, net.options[:open_timeout]
    refute net.options.key?(:cert_store)
  end

  def test_cert_store_is_passed_when_given
    store = OpenSSL::X509::Store.new
    net = FakeNet.new(Ok.new("body"))

    Ferry::Http.new(cert_store: store, net: net).request(Net::HTTP::Get.new(URI("https://example.com/")))

    assert_same store, net.options[:cert_store]
  end

  def test_download_streams_the_body_into_io
    io = StringIO.new

    Ferry::Http.new(net: FakeNet.new(Ok.new("FILE-BYTES"))).download("https://cdn.example/a.jpg", io)

    assert_equal "FILE-BYTES", io.string
  end

  def test_download_failure_raises_api_error_with_status_and_host_only
    net = FakeNet.new(Net::HTTPNotFound.new("1.1", "404", "Not Found"))

    error = assert_raises(Ferry::ApiError) { Ferry::Http.new(net: net).download("https://cdn.example/secret-token/a.jpg", StringIO.new) }

    assert_equal 404, error.code
    assert error.permanent?
    assert_match(/cdn.example/, error.message)
    refute_match(/secret-token/, error.message)
  end

  def test_download_follows_redirects
    redirect = Net::HTTPFound.new("1.1", "302", "Found")
    redirect["location"] = "/real/a.jpg"
    net = FakeNet.new(redirect, Ok.new("FILE-BYTES"))
    io = StringIO.new

    Ferry::Http.new(net: net).download("https://cdn.example/a.jpg", io)

    assert_equal ["https://cdn.example/a.jpg", "https://cdn.example/real/a.jpg"], net.requested
    assert_equal "FILE-BYTES", io.string
  end

  def test_download_gives_up_after_too_many_redirects
    redirects = Array.new(5) do
      Net::HTTPFound.new("1.1", "302", "Found").tap { _1["location"] = "/again" }
    end

    error = assert_raises(Ferry::ApiError) { Ferry::Http.new(net: FakeNet.new(*redirects)).download("https://cdn.example/a", StringIO.new) }

    assert_match(/too many redirects/, error.message)
  end

  def test_network_errors_become_retryable_api_errors_without_the_path
    net = FakeNet.new(Errno::ECONNRESET.new)

    error = assert_raises(Ferry::ApiError) { Ferry::Http.new(net: net).request(Net::HTTP::Get.new(URI("https://api.example/bot-secret-token/x"))) }

    assert_nil error.code
    assert error.retryable?
    assert_match(/api.example/, error.message)
    refute_match(/bot-secret-token/, error.message)
  end
end