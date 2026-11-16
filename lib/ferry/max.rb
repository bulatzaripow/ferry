require "json"
require "net/http"
require "openssl"

require_relative "api_error"
require_relative "http"

module Ferry
  class Max
    API_URL = "https://platform-api2.max.ru".freeze
    DEFAULT_UPDATE_TYPES = %w[message_created chat_title_changed].freeze
    UPLOAD_TYPES = { "image" => "image", "video" => "video", "voice" => "audio", "audio" => "audio", "file" => "file" }.freeze

    def self.cert_store(dir)
      OpenSSL::X509::Store.new.tap do |store|
        store.set_default_paths
        Dir[File.join(dir, "*.{crt,pem}")].sort.each { store.add_file(_1) }
      end
    end

    def initialize(token, certs_dir:, http: nil)
      @token = token
      @http = http || Http.new(cert_store: self.class.cert_store(certs_dir))
    end

    def me = call(Net::HTTP::Get, "/me")

    def get_chat(chat_id) = call(Net::HTTP::Get, "/chats/#{chat_id}")

    def send_message(chat_id:, text:, attachments: nil)
      body = { text: text.to_s.empty? ? nil : text, attachments: attachments }.compact
      call(Net::HTTP::Post, "/messages?chat_id=#{chat_id}", body)
    end

    # Uploads a file and returns an attachment ready for send_message
    def upload(kind, io, filename)
      type = UPLOAD_TYPES.fetch(kind)
      slot = call(Net::HTTP::Post, "/uploads?type=#{type}")

      req = Net::HTTP::Post.new(URI(slot.fetch("url")))
      req.set_form([["data", io, { filename: filename, content_type: "application/octet-stream" }]], "multipart/form-data")
      reply = parse_body(check(@http.request(req), "upload"))

      { type: type, payload: { token: upload_token(reply, slot) } }
    end

    def download(url, io) = @http.download(url, io)

    def subscribe(url:, secret:, update_types: DEFAULT_UPDATE_TYPES)
      reply = call(Net::HTTP::Post, "/subscriptions", url: url, update_types: update_types, secret: secret)
      return reply if reply["success"]

      raise ApiError.new("subscribe: #{reply["message"]}", code: 400)
    end

    private

    def call(verb, path, body = nil)
      req = verb.new(URI("#{API_URL}#{path}"), "Authorization" => @token, "Content-Type" => "application/json")
      req.body = body ? body.to_json : "" if verb::REQUEST_HAS_BODY

      JSON.parse(check(@http.request(req), "#{verb::METHOD} #{path}").body)
    rescue JSON::ParserError => e
      raise ApiError, "#{verb::METHOD} #{path}: #{e.class}: #{e.message}"
    end

    def check(response, what)
      status = response.code.to_i
      return response if status.between?(200, 299)

      body = response.body.to_s
      # the file is uploaded but Max is still processing it: wait and retry
      raise ApiError.new("#{what}: #{body[0, 200]}", code: status, transient: body.match?(/not\.(ready|processed)/))
    end

    # Upload reply: JSON (image, file) or plain text like <retval>1</retval> (video, audio)
    def parse_body(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      {}
    end

    def upload_token(reply, slot)
      photo = reply["photos"]&.values&.first
      token = reply["token"] || photo&.fetch("token", nil) || slot["token"]
      token or raise ApiError, "upload: no token in the response"
    end
  end
end