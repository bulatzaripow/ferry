require "json"
require "sinatra/base"

module Ferry
  class App < Sinatra::Base
    helpers do
      def check_secret(header, expected)
        halt 401 unless Rack::Utils.secure_compare(request.env[header].to_s, expected)
      end

      # A broken body is the sender's fault: answer 400 so that nobody retries it forever
      def update
        JSON.parse(request.body.read)
      rescue JSON::ParserError
        halt 400
      end
    end

    get("/health") { "ok" }

    post "/max" do
      check_secret("HTTP_X_MAX_BOT_API_SECRET", settings.config.max_webhook_secret)

      settings.relay.handle_max_update(update)
      "ok"
    end

    post "/telegram" do
      check_secret("HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN", settings.config.tg_webhook_secret)

      settings.relay.handle_telegram_update(update)
      "ok"
    end
  end
end