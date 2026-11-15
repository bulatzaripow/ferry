module Ferry
  Config = Data.define(:tg_token, :max_token, :tg_group_id, :tg_owner_id, :db_path, :certs_dir) do
    def self.from_env(env = ENV)
      new(
        tg_token:    env.fetch("TELEGRAM_BOT_TOKEN"),
        max_token:   env.fetch("MAX_BOT_TOKEN"),
        tg_group_id: Integer(env.fetch("TELEGRAM_GROUP_ID")),
        tg_owner_id: Integer(env.fetch("TELEGRAM_OWNER_ID")),
        db_path:     env.fetch("DB_PATH", "data/ferry.db"),
        certs_dir:   env.fetch("CERTS_DIR", "certs")
      )
    end
  end
end