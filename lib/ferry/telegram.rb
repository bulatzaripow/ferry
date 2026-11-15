require "json"
require "net/http"

require_relative "api_error"

module Ferry
  class Telegram
    API_URL = "https://api.telegram.org".freeze

    def initialize(token, group_id, http: Net::HTTP)
      @token = token
      @group_id = group_id
      @http = http
    end

    def send_message(topic_id:, text:)
      request("sendMessage", message_thread_id: topic_id, text: text)
    end

    def create_topic(name)
      request("createForumTopic", name: name).fetch("message_thread_id")
    end

    def rename_topic(topic_id, name)
      request("editForumTopic", message_thread_id: topic_id, name: name)
    end

    private

    def request(method, params)
      uri = URI("#{API_URL}/bot#{@token}/#{method}")
      body = params.merge(chat_id: @group_id).to_json
      reply = JSON.parse(@http.post(uri, body, "Content-Type" => "application/json").body)
      return reply["result"] if reply["ok"]

      raise ApiError.new("#{method}: #{reply["description"]}",
                         code: reply["error_code"],
                         retry_after: reply.dig("parameters", "retry_after"))
    rescue *ApiError::TRANSIENT => e
      raise ApiError, "#{method}: #{e.class}: #{e.message}"
    end
  end
end