# Версия языка зафиксирована спецификацией проекта: Ruby 3.3.12.
FROM ruby:3.3.12

ENV LANG=C.UTF-8 \
    BUNDLE_FROZEN=1 \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    # Контейнер может запускаться под произвольным uid хоста (см. compose.yaml),
    # у которого нет домашнего каталога в образе — даём bundler'у и ruby
    # заведомо доступный HOME.
    HOME=/tmp

WORKDIR /app

# Сначала только зависимости — слой кэшируется, пока не меняется Gemfile.
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf "$HOME/.bundle"

COPY . .

# Каталог данных по умолчанию; обычно поверх него монтируется volume.
RUN mkdir -p /data && chmod 0777 /data

EXPOSE 8080

CMD ["bundle", "exec", "bin/syncbox-server"]
