# syntax=docker/dockerfile:1.6

# ---- Builder: compile native gems with full toolchain ----
FROM ruby:4.0-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libsqlite3-dev \
    libxml2-dev \
    libxslt-dev \
    libopenblas-dev \
    liblapack-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without development \
 && bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache \
           /usr/local/bundle/ruby/*/cache

# ---- Runtime: slim image with only what's needed at run time ----
FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    opus-tools \
    sqlite3 \
    libsqlite3-0 \
    libopenblas0-pthread \
    liblapack3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle

COPY . .

RUN mkdir -p db log pids web

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "lib/bot.rb"]
