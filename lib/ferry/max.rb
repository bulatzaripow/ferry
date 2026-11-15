require "json"
require "net/http"
require "openssl"

require_relative "api_error"

module Ferry
  class Max
    API_URL = "https://platform-api2.max.ru".freeze
    DEFAULT_UPDATE_TYPES = %w[message_created chat_title_changed].freeze

    def self.cert_store(dir)
      OpenSSL::X509::Store.new.tap do |store|
        store.set_default_paths
        Dir[File.join(dir, "*.{crt,pem}")].sort.each { store.add_file(_1) }
      end
    end

    def initialize(token, certs_dir:, http: Net::HTTP)
      @token = token
      @cert_store = self.class.cert_store(certs_dir)
      @http = http
    end

    def me = request(Net::HTTP::Get, "/me")

    def get_chat(chat_id) = request(Net::HTTP::Get, "/chats/#{chat_id}")

    def send_message(chat_id:, text:)
      request(Net::HTTP::Post, "/messages?chat_id=#{chat_id}", text: text)
    end

    def subscribe(url:, secret:, update_types: DEFAULT_UPDATE_TYPES)
      reply = request(Net::HTTP::Post, "/subscriptions", url: url, update_types: update_types, secret: secret)
      return reply if reply["success"]

      raise ApiError.new("subscribe: #{reply["message"]}", code: 400)
    end

    private

    def request(verb, path, body = nil)
      uri = URI("#{API_URL}#{path}")
      req = verb.new(uri, "Authorization" => @token, "Content-Type" => "application/json")
      req.body = body.to_json if body

      response = @http.start(uri.host, uri.port, use_ssl: true, cert_store: @cert_store,
                                                 open_timeout: 10, read_timeout: 30) { _1.request(req) }
      status = response.code.to_i
      return JSON.parse(response.body) if status.between?(200, 299)

      raise ApiError.new("#{verb::METHOD} #{path}: #{response.body.to_s[0, 200]}", code: status)
    rescue *ApiError::TRANSIENT => e
      raise ApiError, "#{verb::METHOD} #{path}: #{e.class}: #{e.message}"
    end
  end
end