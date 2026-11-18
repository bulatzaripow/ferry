-- Message ids of both messengers side by side, only to make replies work. No message text is kept here.
CREATE TABLE links (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  max_mid       TEXT    NOT NULL UNIQUE,
  tg_message_id INTEGER NOT NULL UNIQUE,
  created_at    INTEGER NOT NULL
);

CREATE INDEX links_created_at ON links (created_at);