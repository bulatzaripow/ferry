require_relative "test_helper"
require "ferry/config"

class ConfigTest < Minitest::Test
  ENV_OK = {
    "TELEGRAM_BOT_TOKEN" => "tg-token",
    "MAX_BOT_TOKEN"      => "max-token",
    "TELEGRAM_GROUP_ID"  => "-1001234567890",
    "TELEGRAM_OWNER_ID"  => "42"
  }.freeze

  def test_reads_values_from_env
    config = Ferry::Config.from_env(ENV_OK)

    assert_equal "tg-token", config.tg_token
    assert_equal "max-token", config.max_token
    assert_equal(-1001234567890, config.tg_group_id)
    assert_equal 42, config.tg_owner_id
    assert_equal "data/ferry.db", config.db_path
    assert_equal "certs", config.certs_dir
  end

  def test_missing_variable_raises
    assert_raises(KeyError) { Ferry::Config.from_env(ENV_OK.except("MAX_BOT_TOKEN")) }
  end

  def test_non_numeric_id_raises
    assert_raises(ArgumentError) { Ferry::Config.from_env(ENV_OK.merge("TELEGRAM_OWNER_ID" => "abc")) }
  end
end