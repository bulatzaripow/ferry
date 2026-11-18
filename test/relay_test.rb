require_relative "test_helper"
require_relative "fake_store"
require "logger"
require "ferry/relay"

class RelayTest < Minitest::Test
  OWNER = 42
  GROUP = -100

  class FakeWorker
    attr_reader :wakes

    def initialize
      @wakes = 0
    end

    def wake = @wakes += 1
  end

  def setup
    @store = FakeStore.new
    @worker = FakeWorker.new
    @relay = Ferry::Relay.new(store: @store, worker: @worker, owner_id: OWNER, group_id: GROUP, logger: Logger.new(nil))

    # Max chat -77 is already linked to Telegram topic 101
    chat = @store.enqueue(max_chat_id: -77, direction: "tg_to_max", items: [])
    @store.set_topic(chat["id"], 101, "Family")
  end

  # ---- replies

  def test_max_reply_remembers_the_replied_message
    update = max_update(text: "answer")
    update["message"]["link"] = { "type" => "reply", "message" => { "mid" => "mid.7", "text" => "question" } }

    @relay.handle_max_update(update)

    assert_equal "mid.7", payloads.first["reply_to"]
  end

  def test_max_forward_is_not_a_reply
    update = max_update(text: "look")
    update["message"]["link"] = { "type" => "forward", "message" => { "mid" => "mid.7" } }

    @relay.handle_max_update(update)

    refute payloads.first.key?("reply_to")
  end

  def test_only_the_first_part_of_a_long_message_carries_the_reply
    update = max_update(text: "a" * 3900)
    update["message"]["link"] = { "type" => "reply", "message" => { "mid" => "mid.7" } }

    @relay.handle_max_update(update)

    assert_equal ["mid.7", nil], payloads.map { _1["reply_to"] }
  end

  def test_telegram_reply_remembers_the_replied_message
    @relay.handle_telegram_update(telegram_update(text: "answer", extra: { "reply_to_message" => { "message_id" => 55 } }))

    assert_equal({ "text" => "answer", "reply_to" => 55 }, payloads.first)
  end

  def test_telegram_message_in_a_topic_is_not_a_reply_to_the_topic_itself
    @relay.handle_telegram_update(telegram_update(text: "hi", topic: 101, extra: { "reply_to_message" => { "message_id" => 101 } }))

    assert_equal({ "text" => "hi" }, payloads.first)
  end

  # ---- Max -> Telegram: text

  def test_max_message_is_queued_with_author_and_worker_is_woken
    @relay.handle_max_update(max_update(text: "hello", chat_type: "dialog", chat_id: 5))

    assert_equal ["m1:0"], @store.rows.map { _1["source_id"] }
    assert_equal({ "author" => "Ivan Petrov", "chat_type" => "dialog", "mid" => "m1", "text" => "hello" }, payloads.first)
    assert_equal "max_to_tg", @store.rows.first["direction"]
    assert_equal 1, @worker.wakes
  end

  def test_repeated_webhook_does_not_duplicate_message
    2.times { @relay.handle_max_update(max_update(text: "hello")) }

    assert_equal 1, @store.pending
  end

  def test_long_max_message_is_split_in_order
    @relay.handle_max_update(max_update(text: "a" * 3800 + "b" * 100))

    assert_equal %w[m1:0 m1:1], @store.rows.map { _1["source_id"] }
    assert_equal ["a" * 3800, "b" * 100], payloads.map { _1["text"] }
  end

  def test_skipped_max_messages_are_not_queued
    @relay.handle_max_update(max_update(text: "from a bot", sender: { "user_id" => 9, "first_name" => "Bot", "is_bot" => true }))
    @relay.handle_max_update(max_update(text: nil))
    @relay.handle_max_update(max_update(text: "channel", chat_type: "channel"))
    @relay.handle_max_update(max_update(text: "no chat", chat_id: nil))
    @relay.handle_max_update(max_update(text: nil, attachments: [{ "type" => "share", "payload" => { "url" => "https://example.com" } }]))
    @relay.handle_max_update({ "update_type" => "bot_started", "chat_id" => -77 })

    assert_equal 0, @store.pending
    assert_equal 0, @worker.wakes
  end

  def test_author_falls_back_to_username_then_id
    @relay.handle_max_update(max_update(text: "a", mid: "m1", sender: { "user_id" => 7, "username" => "ivan_p" }))
    @relay.handle_max_update(max_update(text: "b", mid: "m2", sender: { "user_id" => 7 }))

    assert_equal %w[ivan_p id7], payloads.map { _1["author"] }
  end

  # ---- Max -> Telegram: attachments

  def test_image_with_text_becomes_one_row_with_caption
    @relay.handle_max_update(max_update(text: "look", attachments: [image("https://cdn.example/a.jpg")]))

    assert_equal 1, @store.pending
    assert_equal "look", payloads.first["text"]
    assert_equal({ "kind" => "image", "url" => "https://cdn.example/a.jpg", "label" => "photo" }, payloads.first["media"])
  end

  def test_attachment_without_text_has_empty_caption
    @relay.handle_max_update(max_update(text: nil, attachments: [image("https://cdn.example/a.jpg")]))

    assert_equal "", payloads.first["text"]
  end

  def test_caption_goes_only_to_the_first_attachment
    @relay.handle_max_update(max_update(text: "two photos", attachments: [image("https://cdn.example/1.jpg"), image("https://cdn.example/2.jpg")]))

    assert_equal %w[m1:0 m1:1], @store.rows.map { _1["source_id"] }
    assert_equal ["two photos", ""], payloads.map { _1["text"] }
  end

  def test_long_text_does_not_fit_a_caption_and_follows_as_separate_text
    text = "x" * 1100
    @relay.handle_max_update(max_update(text: text, attachments: [image("https://cdn.example/a.jpg")]))

    assert_equal ["", text], payloads.map { _1["text"] }
    assert_equal [true, false], payloads.map { _1.key?("media") }
  end

  def test_text_that_fits_a_caption_only_together_with_the_signature
    text = "x" * 1020 # 1020 + the author line is more than 1024
    @relay.handle_max_update(max_update(text: text, attachments: [image("https://cdn.example/a.jpg")]))

    assert_equal ["", text], payloads.map { _1["text"] }
  end

  def test_max_attachment_kinds
    attachments = [
      { "type" => "video", "payload" => { "url" => "https://cdn.example/v.mp4" } },
      { "type" => "audio", "payload" => { "url" => "https://cdn.example/a.m4a" } },
      { "type" => "file", "payload" => { "url" => "https://cdn.example/r.pdf", "filename" => "report.pdf" } }
    ]

    @relay.handle_max_update(max_update(text: nil, attachments: attachments))

    medias = payloads.map { _1["media"] }
    assert_equal %w[video voice file], medias.map { _1["kind"] }
    assert_equal "report.pdf", medias.last["filename"]
    assert_equal "file report.pdf", medias.last["label"]
  end

  def test_location_and_contact_are_announced_with_a_text_row
    attachments = [
      { "type" => "location", "latitude" => 55.75, "longitude" => 37.61 },
      { "type" => "contact", "payload" => { "name" => "Ivan", "vcf_phone" => "+79990001122" } }
    ]

    @relay.handle_max_update(max_update(text: "here", attachments: attachments))

    assert_equal ["here", "", "contact Ivan", ""], payloads.map { _1["text"] }
    assert_equal [nil, "location", nil, "contact"], payloads.map { _1.dig("media", "kind") }
    assert_equal({ "kind" => "contact", "name" => "Ivan", "phone" => "+79990001122", "label" => "contact Ivan" }, payloads.last["media"])
  end

  def test_contact_phone_is_taken_from_vcard_when_needed
    vcard = "BEGIN:VCARD\r\nTEL;TYPE=CELL:+79990001122\r\nEND:VCARD"

    @relay.handle_max_update(max_update(text: nil, attachments: [{ "type" => "contact", "payload" => { "name" => "Ivan", "vcf_info" => vcard } }]))

    assert_equal "+79990001122", payloads.last.dig("media", "phone")
  end

  def test_sticker_is_announced_with_a_text_row
    @relay.handle_max_update(max_update(text: nil, attachments: [{ "type" => "sticker", "payload" => { "url" => "https://cdn.example/s.webp" } }]))

    assert_equal ["sticker", ""], payloads.map { _1["text"] }
    assert_equal "sticker", payloads.last.dig("media", "kind")
  end

  def test_attachments_without_url_are_ignored
    @relay.handle_max_update(max_update(text: "text", attachments: [{ "type" => "image", "payload" => {} }]))

    assert_equal ["text"], payloads.map { _1["text"] }
    assert_nil payloads.first["media"]
  end

  # ---- Telegram -> Max: text

  def test_owner_message_in_known_topic_is_queued_for_max
    @relay.handle_telegram_update(telegram_update(text: "reply", id: 5))

    row = @store.rows.first
    assert_equal "tg_to_max", row["direction"]
    assert_equal "5:0", row["source_id"]
    assert_equal({ "text" => "reply" }, payloads.first)
    assert_equal @store.chat_by_topic(101)["id"], row["chat_id"]
    assert_equal 1, @worker.wakes
  end

  def test_long_telegram_message_is_split_in_order
    @relay.handle_telegram_update(telegram_update(text: "a" * 3800 + "b" * 3800 + "c" * 10))

    assert_equal ["a" * 3800, "b" * 3800, "c" * 10], payloads.map { _1["text"] }
  end

  def test_telegram_messages_that_must_not_be_forwarded
    @relay.handle_telegram_update(telegram_update(text: "stranger", from: 7))
    @relay.handle_telegram_update(telegram_update(text: "other group", chat: -555))
    @relay.handle_telegram_update(telegram_update(text: "no topic", topic: nil))
    @relay.handle_telegram_update(telegram_update(text: "unknown topic", topic: 999))
    @relay.handle_telegram_update(telegram_update(text: nil))
    @relay.handle_telegram_update(telegram_update(text: nil, extra: { "poll" => { "question" => "?" } }))
    @relay.handle_telegram_update({ "edited_message" => { "text" => "edit" } })

    assert_equal 0, @store.pending
    assert_equal 0, @worker.wakes
  end

  # ---- Telegram -> Max: attachments

  def test_telegram_photo_uses_the_largest_size_and_caption
    photo = [{ "file_id" => "small" }, { "file_id" => "big" }]

    @relay.handle_telegram_update(telegram_update(text: nil, extra: { "photo" => photo, "caption" => "look" }))

    assert_equal "look", payloads.first["text"]
    assert_equal({ "kind" => "image", "file_id" => "big", "filename" => "photo.jpg", "label" => "photo" }, payloads.first["media"])
  end

  def test_telegram_attachment_kinds
    {
      "video" => [{ "file_id" => "f1", "file_name" => "clip.mp4" }, "video", "clip.mp4"],
      "video_note" => [{ "file_id" => "f1" }, "video", "video_note.mp4"],
      "animation" => [{ "file_id" => "f1" }, "video", "animation.mp4"],
      "voice" => [{ "file_id" => "f1" }, "voice", "voice.ogg"],
      "audio" => [{ "file_id" => "f1", "file_name" => "song.mp3" }, "audio", "song.mp3"],
      "document" => [{ "file_id" => "f1", "file_name" => "report.pdf" }, "file", "report.pdf"]
    }.each do |field, (value, kind, filename)|
      setup
      @relay.handle_telegram_update(telegram_update(text: nil, extra: { field => value }))

      media = payloads.first["media"]
      assert_equal [kind, "f1", filename], [media["kind"], media["file_id"], media["filename"]], field
    end
  end

  def test_telegram_animation_wins_over_its_document_copy
    extra = { "animation" => { "file_id" => "f1" }, "document" => { "file_id" => "f1", "file_name" => "x.mp4" } }

    @relay.handle_telegram_update(telegram_update(text: nil, extra: extra))

    assert_equal "video", payloads.first.dig("media", "kind")
  end

  def test_telegram_contact_and_location
    @relay.handle_telegram_update(telegram_update(text: nil, id: 1, extra: { "contact" => { "first_name" => "Ivan", "last_name" => "Petrov", "phone_number" => "+7999" } }))
    @relay.handle_telegram_update(telegram_update(text: nil, id: 2, extra: { "location" => { "latitude" => 1.5, "longitude" => 2.5 } }))

    assert_equal({ "kind" => "contact", "name" => "Ivan Petrov", "phone" => "+7999", "label" => "contact Ivan Petrov" }, payloads[0]["media"])
    assert_equal({ "kind" => "location", "latitude" => 1.5, "longitude" => 2.5, "label" => "location" }, payloads[1]["media"])
  end

  def test_telegram_sticker_becomes_a_text_placeholder
    @relay.handle_telegram_update(telegram_update(text: nil, extra: { "sticker" => { "file_id" => "f1", "emoji" => "OK" } }))

    assert_equal({ "text" => "[sticker OK]" }, payloads.first)
  end

  private

  def payloads = @store.rows.map { JSON.parse(_1["payload"]) }

  def image(url) = { "type" => "image", "payload" => { "url" => url, "photo_id" => 1, "token" => "t" } }

  def max_update(text:, chat_type: "chat", chat_id: -77, mid: "m1", attachments: nil,
                 sender: { "user_id" => 1, "first_name" => "Ivan", "last_name" => "Petrov", "is_bot" => false })
    {
      "update_type" => "message_created",
      "message" => {
        "sender" => sender,
        "recipient" => { "chat_id" => chat_id, "chat_type" => chat_type },
        "body" => { "mid" => mid, "text" => text, "attachments" => attachments }
      }
    }
  end

  def telegram_update(text:, id: 1, from: OWNER, chat: GROUP, topic: 101, extra: {})
    { "message" => { "message_id" => id, "from" => { "id" => from }, "chat" => { "id" => chat },
                     "message_thread_id" => topic, "text" => text }.merge(extra) }
  end
end