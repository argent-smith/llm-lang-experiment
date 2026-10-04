FROM ruby:4.0.7

# Containers run as the host user's uid (see compose.yaml), which has no home
# directory inside the image; give bundler and friends somewhere writable.
ENV HOME=/tmp \
    BUNDLE_FROZEN=true

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

COPY . .

EXPOSE 8080
CMD ["bin/syncbox-server"]
