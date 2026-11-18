CREATE TABLE chats (
    id          INTEGER PRIMARY KEY,
    max_chat_id INTEGER NOT NULL UNIQUE,
    title       TEXT,
    tg_topic_id INTEGER UNIQUE
);