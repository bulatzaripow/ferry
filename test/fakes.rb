require "ferry/api_error"

# Stand-in messenger clients for the Courier and Worker tests
class FakeTelegram
  attr_reader :sent, :media, :topics

  def initialize(failures: 0, error: Ferry::ApiError.new("telegram is down"), gone_topics: [], files: {})
    @failures = failures
    @error = error
    @gone_topics = gone_topics
    @files = files
    @sent = []   # text messages: [topic, text]
    @media = []  # everything else: hashes with the attachment kind
    @topics = []
    @media_error = nil
  end

  def fail_media_with(error) = @media_error = error

  def create_topic(name)
    @topics << name
    100 + @topics.size
  end

  def send_message(topic_id:, text:)
    guard(topic_id)
    @sent << [topic_id, text]
  end

  def send_media(topic_id:, kind:, io:, filename:, caption:)
    guard(topic_id)
    raise @media_error if @media_error

    @media << { kind: kind, topic_id: topic_id, filename: filename, caption: caption, content: io.read }
  end

  def send_location(topic_id:, latitude:, longitude:)
    guard(topic_id)
    @media << { kind: "location", topic_id: topic_id, latitude: latitude, longitude: longitude }
  end

  def send_contact(topic_id:, phone:, name:)
    guard(topic_id)
    @media << { kind: "contact", topic_id: topic_id, phone: phone, name: name }
  end

  def download(file_id, io)
    file = @files.fetch(file_id)
    raise file if file.is_a?(Exception)

    io.write(file)
  end

  private

  def guard(topic_id)
    raise Ferry::ApiError.new("sendMessage: Bad Request: message thread not found", code: 400) if @gone_topics.include?(topic_id)

    return unless @failures.positive?

    @failures -= 1
    raise @error
  end
end

class FakeMax
  attr_reader :sent, :attachments, :uploads

  def initialize(down_chats: [], files: {})
    @down_chats = down_chats
    @files = files
    @sent = []         # [chat, text]
    @attachments = []  # attachments, one entry per sent message
    @uploads = []
    @send_errors = []
  end

  def fail_next_send(error) = @send_errors << error

  def get_chat(_chat_id) = { "title" => "Family" }

  def send_message(chat_id:, text:, attachments: nil)
    raise Ferry::ApiError, "max is down" if @down_chats.include?(chat_id)
    raise @send_errors.shift unless @send_errors.empty?

    @sent << [chat_id, text]
    @attachments << attachments
  end

  def upload(kind, io, filename)
    @uploads << { kind: kind, filename: filename, content: io.read }
    { type: kind, payload: { token: "T#{@uploads.size}" } }
  end

  def download(url, io)
    file = @files.fetch(url)
    raise file if file.is_a?(Exception)

    io.write(file)
  end
end