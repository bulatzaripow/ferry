# ---- build stage: compiler and headers live only here
FROM ruby:3.3-slim AS build

ENV BUNDLE_WITHOUT=test

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache


# ---- final stage: only what is needed to run
FROM ruby:3.3-slim

ENV RACK_ENV=production \
    BUNDLE_WITHOUT=test

# The sqlite3 gem may be linked to the system library, so the runtime part is needed
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bundle /usr/local/bundle

RUN useradd --create-home ferry \
    && mkdir -p /app/data \
    && chown -R ferry:ferry /app

WORKDIR /app
COPY --chown=ferry:ferry . .
RUN chmod +x bin/subscribe

USER ferry

EXPOSE 9292

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]