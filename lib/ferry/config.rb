module Ferry
  Config = Data.define(:tg_token, :tg_webhook_secret, :tg_group_id, :tg_owner_id,
                       :max_token, :max_webhook_secret, :db_path, :certs_dir) do
    def self.from_env(env = ENV)
      new(
        tg_token:           env.fetch("TELEGRAM_BOT_TOKEN"),
        tg_webhook_secret:  secret(env, "TELEGRAM_WEBHOOK_SECRET"),
        tg_group_id:        Integer(env.fetch("TELEGRAM_GROUP_ID")),
        tg_owner_id:        Integer(env.fetch("TELEGRAM_OWNER_ID")),
        max_token:          env.fetch("MAX_BOT_TOKEN"),
        max_webhook_secret: secret(env, "MAX_WEBHOOK_SECRET"),
        db_path:            env.fetch("DB_PATH", "data/ferry.db"),
        certs_dir:          env.fetch("CERTS_DIR", "certs")
      )
    end

    def self.secret(env, name)
      value = env.fetch(name)
      return value if value.match?(/\A[\w-]{5,256}\z/)

      raise ArgumentError, "#{name}: 5-256 chars, only A-Z a-z 0-9 _ -"
    end
  end
end