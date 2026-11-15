$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rack/test"
require "ferry/app"

Ferry::App.set :environment, :test