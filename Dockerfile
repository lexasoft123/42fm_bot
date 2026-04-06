FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libsqlite3-dev \
    sqlite3 \
    libxml2-dev \
    libxslt-dev \
    ffmpeg \
    opus-tools \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without development && bundle install

COPY . .

RUN mkdir -p db log pids web

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bundle", "exec", "ruby", "lib/bot.rb"]
