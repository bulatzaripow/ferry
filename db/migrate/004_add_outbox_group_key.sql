-- Telegram sends an album as several messages with a common id; the rows of one album share this key
ALTER TABLE outbox ADD COLUMN group_key TEXT;