# Syncbox (Ruby)

Реализация [SYNCBOX-SPEC.md](SYNCBOX-SPEC.md) на Ruby 4.0.7. Весь код
исполняется в Docker; сборка, volume'ы и порты описаны в
[compose.yaml](compose.yaml), обёртки только выставляют переменные и
вызывают `docker compose`.

## Запуск

    ./run-server --data-dir <path> [--port <n>]   # по умолчанию порт 8080
    ./run-tests                                   # все тесты, код возврата != 0 при падении

Вместо флагов можно задать `SYNCBOX_DATA_DIR` / `SYNCBOX_PORT` (флаги
приоритетнее). Каталог данных создаётся при необходимости и
монтируется в контейнер, порт публикуется на хосте под тем же номером.
Сервер работает на переднем плане; SIGTERM/SIGINT (Ctrl-C) корректно
останавливает и удаляет контейнер. Если обёртку убить через SIGKILL,
убрать остатки придётся вручную (`docker compose ls`, затем
`docker compose -p <project> down`).

## Устройство

- `bin/syncbox-server` — точка входа внутри контейнера.
- `lib/syncbox/server/` — конфигурация (`config.rb`), Rack-приложение
  (`app.rb`), запуск Puma (`cli.rb`).
- `scripts/compose.sh` — общая логика обёрток: отдельный compose-проект
  на каждый запуск, проброс сигналов, `down` при выходе.
- `test/` — minitest: юнит-тесты конфигурации и приложения, интеграционные
  тесты процесса сервера по реальному HTTP.

Gemfile.lock пересобирается внутри контейнера, например
`docker compose run --rm -v "$PWD":/app test bundle lock`.
