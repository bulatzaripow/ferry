require_relative "test_helper"
require "rack/test"
require "ferry/config"
require "ferry/app"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  class FakeRelay
    attr_reader :updates

    def initialize
      @updates = []
    end

    def handle_max_update(update) = @updates << update
  end

  ENV_OK = {
    "TELEGRAM_BOT_TOKEN" => "tg-token",
    "MAX_BOT_TOKEN"      => "max-token",
    "MAX_WEBHOOK_SECRET" => "s3cret-value",
    "TELEGRAM_GROUP_ID"  => "-100",
    "TELEGRAM_OWNER_ID"  => "42"
  }.freeze

  def setup
    @relay = FakeRelay.new
    Ferry::App.set :config, Ferry::Config.from_env(ENV_OK)
    Ferry::App.set :relay, @relay
  end

  def app = Ferry::App

  def test_health
    get "/health"

    assert last_response.ok?
    assert_equal "ok", last_response.body
  end

  def test_max_webhook_passes_update_to_relay
    post "/max", { update_type: "message_created" }.to_json, "HTTP_X_MAX_BOT_API_SECRET" => "s3cret-value"

    assert last_response.ok?
    assert_equal [{ "update_type" => "message_created" }], @relay.updates
  end

  def test_max_webhook_rejects_wrong_secret
    post "/max", "{}", "HTTP_X_MAX_BOT_API_SECRET" => "wrong"

    assert_equal 401, last_response.status
    assert_empty @relay.updates
  end

  def test_max_webhook_rejects_missing_secret
    post "/max", "{}"

    assert_equal 401, last_response.status
    assert_empty @relay.updates
  end
end