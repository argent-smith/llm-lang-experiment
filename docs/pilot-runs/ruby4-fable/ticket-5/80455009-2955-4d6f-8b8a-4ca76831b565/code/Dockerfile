FROM ruby:4.0.7

ENV LANG=C.UTF-8 \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

WORKDIR /app

# Dependencies first so that source edits do not invalidate the gem layer.
COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

# Inside the container the storage root is always /data; the host directory
# passed to run-server is bind-mounted there by compose.yaml.
ENV SYNCBOX_DATA_DIR=/data \
    SYNCBOX_PORT=8080

EXPOSE 8080

CMD ["bin/syncbox-server"]
