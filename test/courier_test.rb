require_relative "test_helper"
require_relative "fake_store"
require_relative "fakes"
require "logger"
require "tmpdir"
require "ferry/courier"

class CourierTest < Minitest::Test
  def setup
    @store = FakeStore.new
    @telegram = FakeTelegram.new(files: { "F1" => "TG-BYTES" })
    @max = FakeMax.new(files: { "https://cdn.example/dir/a.jpg" => "PHOTO", "https://cdn.example/dir/v.m4a" => "VOICE",
                                "https://cdn.example/dir/r.pdf" => "PDF" })
    @courier = Ferry::Courier.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))
  end

  # ---- Max -> Telegram

  def test_photo_with_text_is_sent_as_photo_with_caption
    deliver_from_max({ "text" => "look", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg" } })

    assert_equal [{ kind: "image", topic_id: 101, filename: "a.jpg", caption: "<b>Ivan</b>\nlook", content: "PHOTO" }], @telegram.media
    assert_empty @telegram.sent
  end

  def test_attachment_without_text_gets_a_caption_with_the_author_only
    deliver_from_max({ "text" => "", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg" } })

    assert_equal "<b>Ivan</b>", @telegram.media.first[:caption]
  end

  def test_voice_message_is_sent_as_voice_not_as_a_document
    deliver_from_max({ "text" => "", "media" => { "kind" => "voice", "url" => "https://cdn.example/dir/v.m4a" } })

    assert_equal %w[voice v.m4a VOICE], @telegram.media.first.values_at(:kind, :filename, :content)
  end

  def test_explicit_file_name_wins_over_the_url
    deliver_from_max({ "text" => "", "media" => { "kind" => "file", "url" => "https://cdn.example/dir/r.pdf", "filename" => "report.pdf" } })

    assert_equal %w[file report.pdf], @telegram.media.first.values_at(:kind, :filename)
  end

  def test_location_and_contact_are_sent_natively
    deliver_from_max({ "text" => "", "media" => { "kind" => "location", "latitude" => 1.5, "longitude" => 2.5 } }, id: "m1:0")
    deliver_from_max({ "text" => "", "media" => { "kind" => "contact", "name" => "Ivan", "phone" => "+7999" } }, id: "m2:0")

    assert_equal [{ kind: "location", topic_id: 101, latitude: 1.5, longitude: 2.5 },
                  { kind: "contact", topic_id: 101, phone: "+7999", name: "Ivan" }], @telegram.media
  end

  def test_text_row_is_sent_as_plain_message
    deliver_from_max({ "text" => "hello" })

    assert_equal [[101, "<b>Ivan</b>\nhello"]], @telegram.sent
  end

  def test_temp_files_are_removed
    before = Dir[File.join(Dir.tmpdir, "ferry*")]

    deliver_from_max({ "text" => "", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg" } })

    assert_empty Dir[File.join(Dir.tmpdir, "ferry*")] - before
  end

  def test_signature_is_not_added_in_a_private_dialog
    deliver_from_max({ "chat_type" => "dialog", "text" => "hello" })
    deliver_from_max({ "chat_type" => "dialog", "text" => "", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg" } }, id: "m2:0")

    assert_equal [[101, "hello"]], @telegram.sent
    assert_equal "", @telegram.media.first[:caption]
  end

  def test_user_text_cannot_break_the_html
    deliver_from_max({ "author" => "A<B>", "text" => "1 < 2 & <b>x</b>" })

    assert_equal [[101, "<b>A&lt;B&gt;</b>\n1 &lt; 2 &amp; &lt;b&gt;x&lt;/b&gt;"]], @telegram.sent
  end

  # ---- replies

  def test_max_reply_becomes_a_telegram_reply_to_the_linked_message
    @store.link("mid.question", 900)

    deliver_from_max({ "text" => "answer", "reply_to" => "mid.question" })

    assert_equal [900], @telegram.replies
  end

  def test_reply_to_an_unknown_message_is_sent_as_a_plain_message
    deliver_from_max({ "text" => "answer", "reply_to" => "mid.forgotten" })

    assert_equal 1, @telegram.sent.size
    assert_empty @telegram.replies
  end

  def test_delivered_max_message_is_linked_to_its_telegram_copy
    deliver_from_max({ "text" => "question", "mid" => "mid.1" })

    assert_equal 1001, @store.tg_message_id_for("mid.1")
  end

  def test_attachments_are_linked_too
    deliver_from_max({ "text" => "", "mid" => "mid.2", "media" => { "kind" => "location", "latitude" => 1, "longitude" => 2 } })

    assert_equal 1001, @store.tg_message_id_for("mid.2")
  end

  def test_telegram_reply_becomes_a_max_reply_to_the_linked_message
    @store.link("mid.question", 900)

    deliver_from_telegram({ "text" => "answer", "reply_to" => 900 })

    assert_equal ["mid.question"], @max.replies
  end

  def test_message_sent_to_max_is_linked_to_its_telegram_original
    deliver_from_telegram({ "text" => "question" }, id: "77:0")

    assert_equal "X1", @store.max_mid_for(77)
  end

  def test_a_reply_chain_works_across_both_messengers
    deliver_from_max({ "text" => "question", "mid" => "mid.1" })           # becomes Telegram message 1001
    deliver_from_telegram({ "text" => "answer", "reply_to" => 1001 }, id: "5:0") # owner replies to it

    assert_equal ["mid.1"], @max.replies
    assert_equal "X1", @store.max_mid_for(5)
  end

  # ---- albums

  ALBUM = { "kind" => "album", "label" => "album of 2 files", "items" => [
    { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg", "label" => "photo" },
    { "kind" => "file", "url" => "https://cdn.example/dir/r.pdf", "filename" => "r.pdf", "label" => "file r.pdf" }
  ] }.freeze

  def test_album_from_max_is_sent_as_one_group_with_the_caption
    deliver_from_max({ "text" => "look", "mid" => "mid.1", "media" => ALBUM })

    album = @telegram.media.first
    assert_equal 1, @telegram.media.size
    assert_equal "<b>Ivan</b>\nlook", album[:caption]
    assert_equal [%w[image a.jpg PHOTO], %w[file r.pdf PDF]], album[:items].map { _1.values_at(:kind, :filename, :content) }
    assert_equal 1001, @store.tg_message_id_for("mid.1") # linked to the first message of the album
  end

  def test_album_with_a_bad_file_is_sent_file_by_file_with_a_notice_for_the_bad_one
    @max = FakeMax.new(files: { "https://cdn.example/dir/a.jpg" => "PHOTO",
                                "https://cdn.example/dir/r.pdf" => Ferry::ApiError.new("GET cdn.example: HTTP 404", code: 404) })
    @courier = Ferry::Courier.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))

    deliver_from_max({ "text" => "look", "media" => ALBUM })

    assert_equal ["image"], @telegram.media.map { _1[:kind] }
    assert_equal "<b>Ivan</b>\nlook", @telegram.media.first[:caption]
    assert_match(/\A<b>Ivan<\/b>\n\[!\] Could not forward attachment \(file r.pdf\): GET cdn.example: HTTP 404\z/, @telegram.sent.first.last)
  end

  def test_album_failing_for_a_retryable_reason_is_raised_not_split
    @telegram.fail_media_with(Ferry::ApiError.new("sendMediaGroup: Bad Gateway", code: 502))

    assert_raises(Ferry::ApiError) { deliver_from_max({ "text" => "", "media" => ALBUM }) }
    assert_empty @telegram.sent
  end

  def test_album_from_telegram_becomes_one_max_message_with_several_attachments
    @telegram = FakeTelegram.new(files: { "F1" => "ONE", "F2" => "TWO" })
    @courier = Ferry::Courier.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))
    rows = [
      queue("tg_to_max", { "text" => "", "media" => { "kind" => "image", "file_id" => "F1", "filename" => "photo.jpg" } }, id: "1:0", group: "A1"),
      queue("tg_to_max", { "text" => "the trip", "media" => { "kind" => "image", "file_id" => "F2", "filename" => "photo.jpg" } }, id: "2:0", group: "A1")
    ]

    @courier.deliver(rows.first, rows)

    assert_equal %w[ONE TWO], @max.uploads.map { _1[:content] }
    assert_equal [[-77, "the trip"]], @max.sent
    assert_equal [[{ type: "image", payload: { token: "T1" } }, { type: "image", payload: { token: "T2" } }]], @max.attachments
    assert_equal "X1", @store.max_mid_for(1) # the first part of the album is linked
  end

  def test_files_of_a_telegram_album_are_not_uploaded_again_on_retry
    @telegram = FakeTelegram.new(files: { "F1" => "ONE", "F2" => "TWO" })
    @courier = Ferry::Courier.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))
    @max.fail_next_send(Ferry::ApiError.new("attachment.not.ready", code: 400, transient: true))
    rows = [
      queue("tg_to_max", { "text" => "", "media" => { "kind" => "image", "file_id" => "F1", "filename" => "a.jpg" } }, id: "1:0", group: "A1"),
      queue("tg_to_max", { "text" => "", "media" => { "kind" => "image", "file_id" => "F2", "filename" => "b.jpg" } }, id: "2:0", group: "A1")
    ]

    assert_raises(Ferry::ApiError) { @courier.deliver(rows.first, rows) }
    @courier.deliver(rows.first, rows)

    assert_equal 2, @max.uploads.size
  end

  # ---- Telegram -> Max

  def test_telegram_voice_is_uploaded_and_sent_to_max
    deliver_from_telegram({ "text" => "", "media" => { "kind" => "voice", "file_id" => "F1", "filename" => "voice.ogg" } })

    assert_equal [{ kind: "voice", filename: "voice.ogg", content: "TG-BYTES" }], @max.uploads
    assert_equal [[-77, ""]], @max.sent
    assert_equal [[{ type: "voice", payload: { token: "T1" } }]], @max.attachments
  end

  def test_telegram_document_keeps_its_caption
    deliver_from_telegram({ "text" => "the report", "media" => { "kind" => "file", "file_id" => "F1", "filename" => "report.pdf" } })

    assert_equal [[-77, "the report"]], @max.sent
    assert_equal "report.pdf", @max.uploads.first[:filename]
  end

  def test_telegram_location_and_contact_are_sent_natively
    deliver_from_telegram({ "text" => "", "media" => { "kind" => "location", "latitude" => 1.5, "longitude" => 2.5 } }, id: "1:0")
    deliver_from_telegram({ "text" => "", "media" => { "kind" => "contact", "name" => "Ivan Petrov", "phone" => "+7999" } }, id: "2:0")

    assert_empty @max.uploads
    assert_equal({ type: "location", latitude: 1.5, longitude: 2.5 }, @max.attachments[0].first)
    contact = @max.attachments[1].first
    assert_equal "contact", contact[:type]
    assert_equal "Ivan Petrov", contact[:payload][:name]
    assert_includes contact[:payload][:vcf_info], "FN:Ivan Petrov"
    assert_includes contact[:payload][:vcf_info], "TEL;TYPE=CELL:+7999"
  end

  def test_text_row_goes_to_max_without_attachments
    deliver_from_telegram({ "text" => "reply" })

    assert_equal [[-77, "reply"]], @max.sent
    assert_equal [nil], @max.attachments
  end

  def test_uploaded_file_is_reused_when_sending_is_retried
    @max.fail_next_send(Ferry::ApiError.new("attachment.not.ready", code: 400, transient: true))
    row = queue("tg_to_max", { "text" => "", "media" => { "kind" => "file", "file_id" => "F1", "filename" => "r.pdf" } })

    assert_raises(Ferry::ApiError) { @courier.deliver(row) }
    @courier.deliver(row)

    assert_equal 1, @max.uploads.size
    assert_equal [[{ type: "file", payload: { token: "T1" } }]], @max.attachments
  end

  # ---- attachments that can not be forwarded

  def test_unforwardable_attachment_is_replaced_by_a_notice_to_telegram
    @telegram.fail_media_with(Ferry::ApiError.new("sendPhoto: Bad Request: wrong file", code: 400))

    deliver_from_max({ "text" => "look", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg", "label" => "photo" } })

    assert_empty @telegram.media
    text = @telegram.sent.first.last
    assert_match(/\A<b>Ivan<\/b>\nlook\n\[!\] Could not forward attachment \(photo\): sendPhoto: Bad Request: wrong file\z/, text)
  end

  def test_expired_download_link_is_replaced_by_a_notice
    @max = FakeMax.new(files: { "https://cdn.example/dir/a.jpg" => Ferry::ApiError.new("GET cdn.example: HTTP 404", code: 404) })
    @courier = Ferry::Courier.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))

    deliver_from_max({ "text" => "", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg", "label" => "photo" } })

    assert_match(/\A<b>Ivan<\/b>\n\[!\] Could not forward attachment \(photo\): GET cdn.example: HTTP 404\z/, @telegram.sent.first.last)
  end

  def test_unforwardable_attachment_is_replaced_by_a_notice_to_max
    @telegram = FakeTelegram.new(files: { "F1" => Ferry::ApiError.new("getFile: Bad Request: file is too big", code: 400) })
    @courier = Ferry::Courier.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))

    deliver_from_telegram({ "text" => "the report", "media" => { "kind" => "file", "file_id" => "F1", "label" => "file report.pdf" } })

    assert_equal [nil], @max.attachments
    assert_match(/\Athe report\n\[!\] Could not forward attachment \(file report.pdf\): getFile: Bad Request: file is too big\z/, @max.sent.first.last)
  end

  def test_retryable_error_is_raised_not_replaced
    @telegram.fail_media_with(Ferry::ApiError.new("sendPhoto: Bad Gateway", code: 502))

    assert_raises(Ferry::ApiError) do
      deliver_from_max({ "text" => "", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg" } })
    end
    assert_empty @telegram.sent
  end

  def test_authorization_errors_are_raised_not_replaced
    @telegram.fail_media_with(Ferry::ApiError.new("sendPhoto: Forbidden: bot was kicked", code: 403))

    assert_raises(Ferry::ApiError) do
      deliver_from_max({ "text" => "", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg" } })
    end
  end

  def test_deleted_topic_is_raised_even_for_attachments
    @telegram.fail_media_with(Ferry::ApiError.new("sendPhoto: Bad Request: message thread not found", code: 400))

    assert_raises(Ferry::ApiError) do
      deliver_from_max({ "text" => "", "media" => { "kind" => "image", "url" => "https://cdn.example/dir/a.jpg" } })
    end
  end

  def test_text_rows_are_never_replaced_by_a_notice
    @telegram = FakeTelegram.new(failures: 1, error: Ferry::ApiError.new("sendMessage: Bad Request: wrong", code: 400))
    @courier = Ferry::Courier.new(store: @store, telegram: @telegram, max: @max, logger: Logger.new(nil))

    assert_raises(Ferry::ApiError) { deliver_from_max({ "text" => "hello" }) }
  end

  private

  def deliver_from_max(payload, id: "m1:0")
    @courier.deliver(queue("max_to_tg", { "author" => "Ivan", "chat_type" => "chat" }.merge(payload), id: id))
  end

  def deliver_from_telegram(payload, id: "1:0")
    @courier.deliver(queue("tg_to_max", payload, id: id))
  end

  def queue(direction, payload, id: "m1:0", group: nil)
    chat = @store.enqueue(max_chat_id: -77, direction: direction, items: [[id, payload, group]])
    @store.set_topic(chat["id"], 101, "Family")
    @store.rows.find { _1["direction"] == direction && _1["source_id"] == id }
  end
end