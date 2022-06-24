FROM ruby:3.0

RUN mkdir /app
WORKDIR /app
COPY Gemfile Gemfile.lock /app/
RUN bundle install
COPY . /app

CMD ["/app/bin/console"]
