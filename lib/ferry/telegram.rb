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

    # attachment kind => type inside an album (voice messages and stickers can not be in an album)
    ALBUM_TYPES = { "image" => "photo", "video" => "video", "file" => "document", "audio" => "audio" }.freeze

    def initialize(token, group_id, http: Http.new)
      @token = token
      @group_id = group_id
      @http = http
    end

    # text and caption are HTML (the caller escapes user text); reply_to is a Telegram message id
    def send_message(topic_id:, text:, reply_to: nil)
      call("sendMessage", target(topic_id, reply_to).merge(text: text, parse_mode: "HTML"))
    end

    def send_media(topic_id:, kind:, io:, filename:, caption: nil, reply_to: nil)
      method, field = MEDIA.fetch(kind)
      params = target(topic_id, reply_to)
      params.merge!(caption: caption, parse_mode: "HTML") unless caption.to_s.empty?
      params[:supports_streaming] = true if kind == "video"

      upload(method, params, field => [io, filename])
    end

    def send_media_group(topic_id:, items:, caption: nil, reply_to: nil)
      files = {}
      media = items.each_with_index.map do |item, i|
        files["file#{i}"] = [item[:io], item[:filename]]
        entry = { type: ALBUM_TYPES.fetch(item[:kind]), media: "attach://file#{i}" }
        entry[:supports_streaming] = true if item[:kind] == "video"
        entry
      end
      media.first.merge!(caption: caption, parse_mode: "HTML") unless caption.to_s.empty?

      upload("sendMediaGroup", target(topic_id, reply_to).merge(media: media.to_json), files)
    end

    def send_location(topic_id:, latitude:, longitude:, reply_to: nil)
      call("sendLocation", target(topic_id, reply_to).merge(latitude: latitude, longitude: longitude))
    end

    def send_contact(topic_id:, phone:, name:, reply_to: nil)
      call("sendContact", target(topic_id, reply_to).merge(phone_number: phone, first_name: name))
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

    def target(topic_id, reply_to)
      params = { chat_id: @group_id, message_thread_id: topic_id }
      params[:reply_parameters] = { message_id: reply_to, allow_sending_without_reply: true } if reply_to
      params
    end

    def call(method, params)
      req = Net::HTTP::Post.new(uri_for(method), "Content-Type" => "application/json")
      req.body = params.to_json
      parse(method, @http.request(req))
    end

    def upload(method, params, files)
      req = Net::HTTP::Post.new(uri_for(method))
      form = params.map { |name, value| [name.to_s, value.is_a?(Hash) ? value.to_json : value.to_s] }
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