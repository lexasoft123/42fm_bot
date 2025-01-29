FROM ruby:3.0

RUN apt update && \
    apt install -y sqlite3 && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /app
WORKDIR /app

COPY Gemfile Gemfile.lock /app/

RUN bundle install

COPY . /app

CMD ["/app/bin/console"]
