require "net/http"

require_relative "api_error"

module Ferry
  class Http
    MAX_REDIRECTS = 3

    def initialize(cert_store: nil, net: Net::HTTP)
      @cert_store = cert_store
      @net = net
    end

    def request(req)
      start(req.uri) { _1.request(req) }
    end

    def download(url, io, redirects: MAX_REDIRECTS)
      uri = URI(url)
      location = nil

      start(uri) do |conn|
        conn.request(Net::HTTP::Get.new(uri)) do |response|
          case response
          when Net::HTTPSuccess then response.read_body { io.write(_1) }
          when Net::HTTPRedirection then location = response["location"]
          else raise ApiError.new("GET #{uri.host}: HTTP #{response.code}", code: response.code.to_i)
          end
        end
      end

      return unless location
      raise ApiError, "GET #{uri.host}: too many redirects" if redirects.zero?

      download(URI.join(uri, location).to_s, io, redirects: redirects - 1)
    end

    private

    def start(uri, &)
      options = { use_ssl: true, open_timeout: 10, read_timeout: 60 }
      options[:cert_store] = @cert_store if @cert_store

      @net.start(uri.host, uri.port, **options, &)
    rescue *ApiError::TRANSIENT => e
      raise ApiError, "#{uri.host}: #{e.class}: #{e.message}"
    end
  end
end