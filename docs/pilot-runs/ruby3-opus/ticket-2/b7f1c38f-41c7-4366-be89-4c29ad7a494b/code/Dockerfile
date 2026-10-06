FROM ruby:3.3.12

WORKDIR /app

ENV BUNDLE_FROZEN=true

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

COPY . .
