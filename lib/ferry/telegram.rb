require "json"
require "net/http"

require_relative "api_error"
require_relative "http"

module Ferry
  class Telegram
    API_URL = "https://api.telegram.org".freeze

    # attachment kind => [API method, name of the file field]
    MEDIA = {
      "image"   => %w[sendPhoto photo],
      "video"   => %w[sendVideo video],
      "voice"   => %w[sendVoice voice],
      "audio"   => %w[sendAudio audio],
      "file"    => %w[sendDocument document],
      "sticker" => %w[sendSticker sticker]
    }.freeze

    def initialize(token, group_id, http: Http.new)
      @token = token
      @group_id = group_id
      @http = http
    end

    def send_message(topic_id:, text:)
      call("sendMessage", chat_id: @group_id, message_thread_id: topic_id, text: text)
    end

    def send_media(topic_id:, kind:, io:, filename:, caption: nil)
      method, field = MEDIA.fetch(kind)
      params = { chat_id: @group_id, message_thread_id: topic_id }
      params[:caption] = caption unless caption.to_s.empty?
      params[:supports_streaming] = true if kind == "video"

      upload(method, params, field => [io, filename])
    end

    def send_location(topic_id:, latitude:, longitude:)
      call("sendLocation", chat_id: @group_id, message_thread_id: topic_id, latitude: latitude, longitude: longitude)
    end

    def send_contact(topic_id:, phone:, name:)
      call("sendContact", chat_id: @group_id, message_thread_id: topic_id, phone_number: phone, first_name: name)
    end

    def create_topic(name)
      call("createForumTopic", chat_id: @group_id, name: name).fetch("message_thread_id")
    end

    def rename_topic(topic_id, name)
      call("editForumTopic", chat_id: @group_id, message_thread_id: topic_id, name: name)
    end

    def set_webhook(url:, secret:)
      call("setWebhook", url: url, secret_token: secret, allowed_updates: %w[message])
    end

    # Downloads a file by file_id into io. The cloud Bot API serves files up to 20 MB only.
    def download(file_id, io)
      path = call("getFile", file_id: file_id).fetch("file_path")
      @http.download("#{API_URL}/file/bot#{@token}/#{path}", io)
    end

    private

    def call(method, params)
      req = Net::HTTP::Post.new(uri_for(method), "Content-Type" => "application/json")
      req.body = params.to_json
      parse(method, @http.request(req))
    end

    def upload(method, params, files)
      req = Net::HTTP::Post.new(uri_for(method))
      form = params.map { |name, value| [name.to_s, value.to_s] }
      files.each { |field, (io, filename)| form << [field, io, { filename: filename, content_type: "application/octet-stream" }] }
      req.set_form(form, "multipart/form-data")
      parse(method, @http.request(req))
    end

    def uri_for(method) = URI("#{API_URL}/bot#{@token}/#{method}")

    def parse(method, response)
      reply = JSON.parse(response.body)
      return reply["result"] if reply["ok"]

      raise ApiError.new("#{method}: #{reply["description"]}",
                         code: reply["error_code"],
                         retry_after: reply.dig("parameters", "retry_after"))
    rescue JSON::ParserError => e
      raise ApiError, "#{method}: #{e.class}: #{e.message}"
    end
  end
end