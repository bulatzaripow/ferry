# ferry

Bridges [Max](https://max.ru) and Telegram in both directions.

## Run on a server

You need a server with Docker, a domain pointing to it, and open ports 80 and 443.

1. **Telegram:** create a group, enable topics (forum mode), add your bot and make it an admin with the "Manage topics" right.
2. **Max:** create a bot and add it to the Max groups you want to forward.
3. **Configure:**
   ```
   cp .env.example .env
   ```
   Fill in `.env`: both bot tokens, the Telegram group id (starts with `-100`), your Telegram user id, `DOMAIN`, `PUBLIC_URL` and two webhook secrets (5-256 chars: letters, digits, `_`, `-`).
4. **Get the Max certificate** (Max API uses the Russian Trusted CA):
   ```
   curl -o certs/russian_trusted_root_ca.pem https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt
   ```
   If you still get TLS errors, also put the issuing certificate from https://www.gosuslugi.ru/crt into `certs/`.
5. **Start:**
   ```
   docker compose up -d --build
   curl https://YOUR_DOMAIN/health
   ```
6. **Subscribe the webhooks** (once; repeat if the server was down for more than 8 hours, Max drops the subscription):
   ```
   docker compose run --rm ferry bin/subscribe
   ```

Logs: `docker compose logs -f ferry`.

## Develop

```
bundle install
bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].each { require_relative _1 }'
```

## Limitations

- Delivery is at-least-once: a rare duplicate is possible after a crash.
- Files from Telegram are limited to 20 MB (Bot API limit).
- Max video circles cannot be forwarded (Max issue); forwarded messages and photo albums are not grouped or supported.
