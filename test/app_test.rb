require_relative "test_helper"
require "rack/test"
require "ferry/app"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app = Ferry::App

  def test_health
    get "/health"
    puts "STATUS: #{last_response.status}"
    puts "BODY:   #{last_response.body.inspect}"
    assert last_response.ok?
    assert_equal "ok", last_response.body
  end
end