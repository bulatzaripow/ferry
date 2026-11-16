require_relative "lib/ferry"

config = Ferry::Config.from_env

relay = Ferry::Relay.new(
  store:    Ferry::Store.new(Ferry::DB.connect(config.db_path)),
  telegram: Ferry::Telegram.new(config.tg_token, config.tg_group_id),
  max:      Ferry::Max.new(config.max_token, certs_dir: config.certs_dir),
  owner_id: config.tg_owner_id,
  group_id: config.tg_group_id
)

Ferry::App.set :config, config
Ferry::App.set :relay, relay
run Ferry::App