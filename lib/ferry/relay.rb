require "logger"

module Ferry
  class Relay
    CHAT_TYPES = %w[dialog chat].freeze
    PART = /.{1,3800}/m # Max accepts 4000 characters, Telegram 4096; the rest is a reserve for the author name
    CAPTION_LIMIT = 1024 # caption of a file in Telegram
    ALBUM_KINDS = { "image" => :visual, "video" => :visual, "file" => :file }.freeze # what Telegram can group
    ALBUM_SIZE = 10 # most files in one Telegram album
    ALBUM_WAIT = 5 # seconds to wait for the other parts of a Telegram album
    NO_CAPTION = %w[location contact sticker].freeze # Telegram has no captions for these

    def initialize(store:, worker:, owner_id:, group_id:, logger: Logger.new($stdout), clock: -> { Time.now.to_i })
      @store = store
      @worker = worker
      @owner_id = owner_id
      @group_id = group_id
      @logger = logger
      @clock = clock
    end

    def handle_max_update(update)
      return unless update["update_type"] == "message_created"

      message = update["message"]
      body = message["body"] || {}
      text = body["text"].to_s
      medias = Array(body["attachments"]).filter_map { max_media(_1) }

      if (reason = max_skip_reason(message, text, medias))
        @logger.info("max: message skipped (#{reason})")
        return
      end

      payloads = max_payloads(author_name(message["sender"]), message.dig("recipient", "chat_type"), body["mid"], text, medias)
      reply_to = message.dig("link", "message", "mid") if message.dig("link", "type") == "reply"
      payloads.first["reply_to"] = reply_to if reply_to
      queue(message.dig("recipient", "chat_id"), "max_to_tg", body["mid"], payloads)
    end

    def handle_telegram_update(update)
      message = update["message"]
      return unless message

      text = (message["text"] || message["caption"]).to_s
      media = telegram_media(message)
      text = "[#{["sticker", message.dig("sticker", "emoji")].compact.join(" ")}]" if message["sticker"] && text.empty?

      if (reason = telegram_skip_reason(message, text, media))
        @logger.info("telegram: message skipped (#{reason})")
        return
      end

      unless (chat = @store.chat_by_topic(message["message_thread_id"]))
        @logger.info("telegram: message skipped (unknown topic #{message["message_thread_id"]})")
        return
      end

      payloads = media ? [{ "text" => text, "media" => media }] : text.scan(PART).map { { "text" => _1 } }
      reply_to = message.dig("reply_to_message", "message_id")
      # inside a topic every plain message "replies" to the service message that created the topic
      payloads.first["reply_to"] = reply_to if reply_to && reply_to != message["message_thread_id"]
      queue(chat["max_chat_id"], "tg_to_max", message["message_id"], payloads, group: (message["media_group_id"] if media))
    end

    private

    def queue(max_chat_id, direction, source_id, payloads, group: nil)
      items = payloads.each_with_index.map { |payload, i| ["#{source_id}:#{i}", payload, group] }
      due_at = group ? @clock.call + ALBUM_WAIT : 0
      @store.enqueue(max_chat_id: max_chat_id, direction: direction, items: items, due_at: due_at)
      @logger.info("#{direction}: queued #{items.map(&:first).join(", ")}")
      @worker.wake
    end

    # ---- Max -> Telegram

    # Queue rows: the caption goes with the first file that can have one; if it does not fit it is sent as separate text
    def max_payloads(author, chat_type, mid, text, medias)
      base = { "author" => author, "chat_type" => chat_type, "mid" => mid }
      payloads = []

      albums(medias).each do |media|
        if NO_CAPTION.include?(media["kind"])
          payloads.concat(text_payloads(base, text.empty? ? media["label"] : text))
          text = ""
          payloads << base.merge("text" => "", "media" => media)
        elsif !text.empty? && "#{author}\n#{text}".length <= CAPTION_LIMIT
          payloads << base.merge("text" => text, "media" => media)
          text = ""
        else
          payloads << base.merge("text" => "", "media" => media)
        end
      end

      payloads.concat(text_payloads(base, text)) unless text.empty?
      payloads
    end

    def albums(medias)
      medias
        .slice_when { |a, b| !ALBUM_KINDS.key?(a["kind"]) || ALBUM_KINDS[a["kind"]] != ALBUM_KINDS[b["kind"]] }
        .flat_map { |run| ALBUM_KINDS.key?(run.first["kind"]) ? run.each_slice(ALBUM_SIZE).map { album(_1) } : run }
    end

    def album(run) = run.one? ? run.first : { "kind" => "album", "items" => run, "label" => "album of #{run.size} files" }

    def text_payloads(base, text) = text.scan(PART).map { base.merge("text" => _1) }

    def max_media(attachment)
      payload = attachment["payload"] || {}
      url = payload["url"]

      case attachment["type"]
      when "image"   then url && { "kind" => "image", "url" => url, "label" => "photo" }
      when "video"   then url && { "kind" => "video", "url" => url, "label" => "video" }
      when "audio"   then url && { "kind" => "voice", "url" => url, "label" => "voice message" }
      when "file"    then url && { "kind" => "file", "url" => url, "filename" => payload["filename"], "label" => "file #{payload["filename"]}".strip }
      when "sticker" then url && { "kind" => "sticker", "url" => url, "label" => "sticker" }
      when "location" then max_location(attachment)
      when "contact"  then max_contact(payload)
      end
    end

    def max_location(attachment)
      { "kind" => "location", "latitude" => attachment["latitude"], "longitude" => attachment["longitude"], "label" => "location" }
    end

    def max_contact(payload)
      phone = payload["vcf_phone"] || payload["vcf_info"].to_s[/^TEL[^:\r\n]*:([^\r\n]+)/i, 1]
      return unless phone

      { "kind" => "contact", "name" => payload["name"] || phone, "phone" => phone, "label" => "contact #{payload["name"]}".strip }
    end

    def max_skip_reason(message, text, medias)
      sender = message["sender"]

      case
      when !CHAT_TYPES.include?(message.dig("recipient", "chat_type")) then "unsupported chat type"
      when message.dig("recipient", "chat_id").nil? then "no chat id"
      when sender.nil? || sender["is_bot"] then "sent by a bot or a channel"
      when text.empty? && medias.empty? then "nothing to forward"
      end
    end

    # ---- Telegram -> Max

    def telegram_media(message)
      if (photo = message["photo"]&.last)
        { "kind" => "image", "file_id" => photo["file_id"], "filename" => "photo.jpg", "label" => "photo" }
      elsif (video = message["video"])
        { "kind" => "video", "file_id" => video["file_id"], "filename" => video["file_name"] || "video.mp4", "label" => "video" }
      elsif (note = message["video_note"])
        { "kind" => "video", "file_id" => note["file_id"], "filename" => "video_note.mp4", "label" => "video message" }
      elsif (animation = message["animation"])
        { "kind" => "video", "file_id" => animation["file_id"], "filename" => animation["file_name"] || "animation.mp4", "label" => "animation" }
      elsif (voice = message["voice"])
        { "kind" => "voice", "file_id" => voice["file_id"], "filename" => "voice.ogg", "label" => "voice message" }
      elsif (audio = message["audio"])
        { "kind" => "audio", "file_id" => audio["file_id"], "filename" => audio["file_name"] || "audio.mp3", "label" => "audio" }
      elsif (document = message["document"])
        { "kind" => "file", "file_id" => document["file_id"], "filename" => document["file_name"] || "file", "label" => "file #{document["file_name"]}".strip }
      elsif (contact = message["contact"])
        name = [contact["first_name"], contact["last_name"]].compact.join(" ")
        { "kind" => "contact", "name" => name, "phone" => contact["phone_number"], "label" => "contact #{name}".strip }
      elsif (location = message["location"])
        { "kind" => "location", "latitude" => location["latitude"], "longitude" => location["longitude"], "label" => "location" }
      end
    end

    def telegram_skip_reason(message, text, media)
      case
      when message.dig("from", "id") != @owner_id || message.dig("chat", "id") != @group_id then "not from the owner in the group"
      when message["message_thread_id"].nil? then "not in a topic"
      when text.empty? && media.nil? then "nothing to forward"
      end
    end

    def author_name(sender)
      name = sender.values_at("first_name", "last_name").join(" ").strip
      name.empty? ? (sender["username"] || "id#{sender["user_id"]}") : name
    end
  end
end