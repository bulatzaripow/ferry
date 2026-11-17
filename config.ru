require "logger"
require_relative "lib/ferry"

config = Ferry::Config.from_env

# Logs go to stdout: Docker collects them (docker compose logs -f ferry)
$stdout.sync = true
logger = Logger.new($stdout, level: config.log_level, progname: "ferry")

store    = Ferry::Store.new(Ferry::DB.connect(config.db_path))
telegram = Ferry::Telegram.new(config.tg_token, config.tg_group_id)
max      = Ferry::Max.new(config.max_token, certs_dir: config.certs_dir)

courier = Ferry::Courier.new(store:, telegram:, max:, logger:)
worker  = Ferry::Worker.new(store:, courier:, logger:)
relay   = Ferry::Relay.new(store:, worker:, owner_id: config.tg_owner_id, group_id: config.tg_group_id, logger:)
worker.start

Ferry::App.set :config, config
Ferry::App.set :relay, relay
run Ferry::App