CREATE TABLE outbox (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id         INTEGER NOT NULL REFERENCES chats (id),
  direction       TEXT    NOT NULL CHECK (direction IN ('max_to_tg', 'tg_to_max')),
  source_id       TEXT    NOT NULL,
  payload         TEXT    NOT NULL,
  attempts        INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  last_error      TEXT,
  UNIQUE (direction, source_id)
);

CREATE INDEX outbox_queue ON outbox (chat_id, direction, id);