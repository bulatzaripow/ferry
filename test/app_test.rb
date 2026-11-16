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

    def handle_max_update(update) = @updates << [:max, update]

    def handle_telegram_update(update) = @updates << [:telegram, update]
  end

  ENV_OK = {
    "TELEGRAM_BOT_TOKEN" => "tg-token",
    "MAX_BOT_TOKEN"      => "max-token",
    "MAX_WEBHOOK_SECRET" => "s3cret-value",
    "TELEGRAM_WEBHOOK_SECRET" => "other_secret-1",
    "TELEGRAM_GROUP_ID"  => "-100",
    "TELEGRAM_OWNER_ID"  => "42"
  }.freeze

  def setup
    @relay = FakeRelay.new
    Ferry::App.set :config, Ferry::Config.from_env(ENV_OK)
    Ferry::App.set :host_authorization, permitted_hosts: ["example.org"]
    Ferry::App.set :relay, @relay
  end

  def app = Ferry::App

  def test_health
    get "/health"

    assert last_response.ok?
    assert_equal "ok", last_response.body
  end

  def test_max_webhook_passes_update_to_relay
    post "/max", { update_type: "message_created" }.to_json, "HTTP_X_MAX_BOT_API_SECRET" => "s3cret-value", "CONTENT_TYPE" => "application/json"
    
    assert last_response.ok?
    assert_equal [[:max, { "update_type" => "message_created" }]], @relay.updates
  end

  def test_telegram_webhook_passes_update_to_relay
    post "/telegram", { message: { text: "hi" } }.to_json, "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "other_secret-1", "CONTENT_TYPE" => "application/json"

    assert last_response.ok?
    assert_equal [[:telegram, { "message" => { "text" => "hi" } }]], @relay.updates
  end

  def test_telegram_webhook_rejects_wrong_secret
    post "/telegram", "{}", "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "s3cret-value"

    assert_equal 401, last_response.status
    assert_empty @relay.updates
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