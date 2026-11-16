require "json"
require "sinatra/base"

module Ferry
  class App < Sinatra::Base
    get("/health") { "ok" }

    post "/max" do
      secret = request.env["HTTP_X_MAX_BOT_API_SECRET"].to_s
      halt 401 unless Rack::Utils.secure_compare(secret, settings.config.max_webhook_secret)

      settings.relay.handle_max_update(JSON.parse(request.body.read))
      "ok"
    end
  end
end