require "sinatra/base"

module Ferry
  class App < Sinatra::Base
    get("/health") { "ok" }
  end
end