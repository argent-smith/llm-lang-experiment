# Syncbox

Самостоятельно хостящееся файловое хранилище с синхронизацией: HTTP-сервер
хранит блобы на диске, CLI-клиент синхронизирует с ним локальную папку.
Контракт — в [SYNCBOX-SPEC.md](SYNCBOX-SPEC.md) и
[syncbox-openapi.yaml](syncbox-openapi.yaml).

Реализация на Ruby 3.3.12 (базовый образ `ruby:3.3.12`). Весь код — сервер,
клиент, тесты — исполняется только внутри Docker-контейнеров через
`docker compose`; на хосте нужны лишь `bash` и Docker с плагином compose.

## Состояние

Тикет 1 — каркас сервера:

- `GET /healthz` → `200`, `{"status":"ok"}`;
- конфигурация через `--data-dir <path>` (обязателен) и `--port <n>`
  (по умолчанию `8080`) либо `SYNCBOX_DATA_DIR` / `SYNCBOX_PORT`
  (флаг имеет приоритет над переменной);
- Dockerfile, `compose.yaml`, обёртки `run-server` и `run-tests`.

Эндпоинты `/blobs` и `/blobs/{key}`, а также клиент — следующие тикеты.

## Запуск

```sh
./run-server --data-dir ./data --port 8080
# или
SYNCBOX_DATA_DIR=./data SYNCBOX_PORT=8080 ./run-server

curl -i http://127.0.0.1:8080/healthz
```

`run-server` работает в текущем процессе (без демонизации); Ctrl-C или
SIGTERM корректно останавливают сервер и удаляют контейнер. Каталог данных —
путь на хосте: обёртка создаёт его при отсутствии и монтирует в контейнер как
`/data`. Контейнер запускается под uid/gid вызывающего пользователя, поэтому
файлы в каталоге данных не достаются `root`'у.

Каждый запуск живёт в отдельном compose-проекте `syncbox-<port>`, так что
несколько серверов на разных портах не мешают друг другу.

## Тесты

```sh
./run-tests
```

Собирает образ и прогоняет все тесты (minitest) в контейнере; код возврата
ненулевой, если хоть один тест упал. Интеграционные тесты запускают
настоящий `bin/syncbox-server` отдельным процессом и ходят в него по HTTP.

## Устройство

```
bin/syncbox-server          точка входа сервера (внутри контейнера)
lib/syncbox/config.rb       разбор флагов и переменных окружения
lib/syncbox/app.rb          Rack-приложение: маршруты HTTP API
lib/syncbox/server.rb       запуск Puma с приложением
lib/syncbox/cli.rb          коды возврата, подготовка каталога данных
test/                       minitest: юнит-тесты и интеграционные тесты
Dockerfile, compose.yaml    сборка образа, сервисы `server` и `test`
run-server, run-tests       обёртки, вызывающие только `docker compose`
```

Коды возврата `bin/syncbox-server`: `0` — штатное завершение, `1` — не
удалось подготовить каталог данных, `2` — ошибка в аргументах (usage).

Внутри контейнера сервер слушает `0.0.0.0:<port>`; снаружи порт доступен
через публикацию `<port>:<port>` в `compose.yaml`.

Зависимости: [puma](https://github.com/puma/puma) (HTTP-сервер),
[rack](https://github.com/rack/rack); для тестов — minitest и rack-test.
Версии зафиксированы в `Gemfile.lock`, образ собирается с
`BUNDLE_FROZEN=1`. Чтобы обновить зависимости, поменяйте `Gemfile` и
перегенерируйте lock внутри контейнера, например:

```sh
docker compose run --rm -T test bundle lock --print > Gemfile.lock
```
