require "cgi"
require "json"
require "logger"
require "tempfile"
require "uri"

require_relative "api_error"

module Ferry
  # Delivers one queued message: text, file, contact or location.
  # ApiError is not swallowed here: retries are the Worker's job. The one exception is an attachment
  # that can never be forwarded (too big, wrong format): a text notice is sent instead, so that the
  # queue does not get stuck behind it.
  class Courier
    def initialize(store:, telegram:, max:, logger: Logger.new($stdout))
      @store = store
      @telegram = telegram
      @max = max
      @logger = logger
      @uploaded = {} # row id => Max attachment that is already uploaded (a retry must not upload again)
    end

    def deliver(row, group = [row])
      row = merge_album(group) if group.size > 1
      chat = @store.chat(row["chat_id"])
      payload = JSON.parse(row["payload"])

      begin
        send_row(row, chat, payload)
      rescue ApiError => e
        raise unless payload["media"] && e.permanent? && !e.topic_gone?

        @logger.error("#{row["direction"]}: #{row["source_id"]} attachment can't be forwarded, sending a notice (#{e.message})")
        payload["media"]["kind"] == "album" ? send_separately(row, chat, payload) : send_notice(row, chat, payload, e)
      end

      @uploaded.delete(row["id"]) # on failure the entry stays in the cache until the retry
    end

    private

    def send_row(row, chat, payload)
      case row["direction"]
      when "max_to_tg" then to_telegram(chat, payload)
      when "tg_to_max" then to_max(row, chat, payload)
      end
    end

    # ---- Max -> Telegram

    def to_telegram(chat, payload)
      topic_id = chat["tg_topic_id"] || create_topic(chat, payload)
      media = payload["media"]
      text = html(payload)
      reply_to = payload["reply_to"] && @store.tg_message_id_for(payload["reply_to"])

      sent = case media&.fetch("kind")
             when nil        then @telegram.send_message(topic_id: topic_id, text: text, reply_to: reply_to)
             when "location" then @telegram.send_location(topic_id: topic_id, latitude: media["latitude"], longitude: media["longitude"], reply_to: reply_to)
             when "contact"  then @telegram.send_contact(topic_id: topic_id, phone: media["phone"], name: media["name"], reply_to: reply_to)
             when "album"
               with_files(media["items"]) do |ios|
                 items = media["items"].zip(ios).map { |item, io| { kind: item["kind"], io: io, filename: filename(item) } }
                 @telegram.send_media_group(topic_id: topic_id, items: items, caption: text, reply_to: reply_to)
               end
             else
               with_file(media) do |io|
                 @telegram.send_media(topic_id: topic_id, kind: media["kind"], io: io, filename: filename(media), caption: text, reply_to: reply_to)
               end
             end

      first = sent.is_a?(Array) ? sent.first : sent # an album answers with a list of messages
      @store.link(payload["mid"], first["message_id"]) if payload["mid"] && first
    end

    # The author goes on its own bold line above the text. Private dialogs have one author, so no signature there.
    def html(payload)
      text = CGI.escapeHTML(payload["text"].to_s)
      return text if payload["chat_type"] == "dialog"

      ["<b>#{CGI.escapeHTML(payload["author"].to_s)}</b>", text].reject(&:empty?).join("\n")
    end

    def create_topic(chat, payload)
      name = payload["chat_type"] == "dialog" ? payload["author"] : @max.get_chat(chat["max_chat_id"])["title"]
      name = "Max #{chat["max_chat_id"]}" if name.to_s.strip.empty?
      name = name[0, 128]

      topic_id = @telegram.create_topic(name)
      @store.set_topic(chat["id"], topic_id, name)
      topic_id
    end

    # ---- Telegram -> Max

    def to_max(row, chat, payload)
      media = payload["media"]
      attachments = media && max_attachments(row, media)
      reply_to = payload["reply_to"] && @store.max_mid_for(payload["reply_to"])

      sent = @max.send_message(chat_id: chat["max_chat_id"], text: payload["text"], attachments: attachments, reply_to: reply_to)
      mid = sent&.dig("message", "body", "mid")
      @store.link(mid, row["source_id"].to_i) if mid # source_id is "<telegram message id>:<part>"
    end

    def max_attachments(row, media)
      case media["kind"]
      when "location" then [{ type: "location", latitude: media["latitude"], longitude: media["longitude"] }]
      when "contact"  then [{ type: "contact", payload: { name: media["name"], vcf_info: vcard(media) } }]
      when "album"    then media["items"].each_with_index.map { |item, i| uploaded(row, i, item) }
      else [uploaded(row, 0, media)]
      end
    end

    # Uploads a file once: when the message has to be sent again, the files are not uploaded again
    def uploaded(row, index, media)
      (@uploaded[row["id"]] ||= {})[index] ||= with_file(media) { |io| @max.upload(media["kind"], io, filename(media)) }
    end

    def vcard(media)
      "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:#{media["name"]}\r\nTEL;TYPE=CELL:#{media["phone"]}\r\nEND:VCARD"
    end

    # ---- shared

    # Downloads the file into a temp file (deleted right after the block) and yields it
    def with_file(media)
      Tempfile.create("ferry", binmode: true) do |io|
        media["url"] ? @max.download(media["url"], io) : @telegram.download(media["file_id"], io)
        io.flush
        io.rewind
        yield io
      end
    end

    # Downloads several files and yields the list of open temp files
    def with_files(medias, ios = [], &)
      return yield(ios) if medias.empty?

      with_file(medias.first) { |io| with_files(medias.drop(1), ios + [io], &) }
    end

    # Several rows of one Telegram album become one row with an "album" attachment
    def merge_album(rows)
      payloads = rows.map { JSON.parse(_1["payload"]) }
      album = { "kind" => "album", "items" => payloads.map { _1["media"] }, "label" => "album of #{rows.size} files" }
      caption = payloads.map { _1["text"].to_s }.find { !_1.empty? }.to_s

      rows.first.merge("payload" => payloads.first.merge("text" => caption, "media" => album).to_json)
    end

    def filename(media) = media["filename"] || File.basename(URI(media["url"].to_s).path).then { _1.empty? ? "file" : _1 }

    # An album that can not be sent as a whole: send the files one by one, so one bad file does not spoil the rest
    def send_separately(row, chat, payload)
      payload["media"]["items"].each_with_index do |item, i|
        part = row.merge("id" => "#{row["id"]}.#{i}") # its own upload cache entry
        single = payload.merge("media" => item, "text" => i.zero? ? payload["text"] : "")

        begin
          send_row(part, chat, single)
        rescue ApiError => e
          raise unless e.permanent? && !e.topic_gone?

          send_notice(part, chat, single, e)
        ensure
          @uploaded.delete(part["id"])
        end
      end
    end

    def send_notice(row, chat, payload, error)
      note = [payload["text"].to_s, "[!] Could not forward attachment (#{payload.dig("media", "label")}): #{error.message[0, 150]}"]
             .reject(&:empty?).join("\n")

      send_row(row, chat, payload.merge("text" => note, "media" => nil))
    end
  end
end