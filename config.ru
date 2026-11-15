require_relative "lib/ferry"

Ferry::App.set :config, Ferry::Config.from_env
run Ferry::App