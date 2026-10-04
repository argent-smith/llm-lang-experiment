# Syncbox (Python)

Самостоятельно хостящееся файловое хранилище с синхронизацией. Контракт —
[SYNCBOX-SPEC.md](SYNCBOX-SPEC.md) и [syncbox-openapi.yaml](syncbox-openapi.yaml).

Всё исполняется в Docker через `docker compose` ([compose.yaml](compose.yaml));
на хосте нужны только Docker с плагином compose и bash.

## Запуск

```sh
./run-server --data-dir ./data --port 8080   # или SYNCBOX_DATA_DIR / SYNCBOX_PORT
./run-tests                                  # все тесты; аргументы уходят в pytest
```

`run-server` работает на переднем плане, останавливается по SIGTERM/SIGINT
(контейнер при этом удаляется). Каталог данных создаётся, если его нет,
и монтируется в контейнер; файлы пишутся от имени вызывающего пользователя.
Порт публикуется на `127.0.0.1`; другой адрес — через `SYNCBOX_PUBLISH_ADDR`
(например `0.0.0.0`).

## Устройство

- `syncbox/server/` — HTTP-сервер на стандартной библиотеке
  (`http.server.ThreadingHTTPServer`), без внешних зависимостей.
  Точка входа: `python -m syncbox.server --data-dir PATH [--port N]`.
- `tests/` — pytest: конфигурация, HTTP-слой in-process, сервер как
  реальный процесс.
- `Dockerfile` — стадии `runtime` (сервер) и `test` (+ pytest и тесты).
