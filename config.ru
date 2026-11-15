require_relative "lib/ferry"

config = Ferry::Config.from_env

Ferry::App.set :config, config
Ferry::App.set :db, Ferry::DB.connect(config.db_path)
run Ferry::App