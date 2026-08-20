# Мануал: запуск и проверка

Как поднять и проверить проект локально через [Makefile](../Makefile).
Актуально для служебной эталонной реализации (`acceptance/reference-impl`)
и остаётся годным для будущих языковых реализаций — цели Makefile
параметризованы `IMPL`/`PORT`.

## Предпосылки

- `git`.
- `docker` — Docker Desktop на macOS/Windows или Docker Engine на Linux.
  Демон должен быть запущен (`docker info` отвечает без ошибки).
- `shellcheck` (`brew install shellcheck` на macOS, `apt install
  shellcheck` на Debian/Ubuntu — на GitHub Actions `ubuntu-latest` уже
  установлен).
- `python3` (3.9+) — под него создаётся локальное `.venv` с
  `openapi-spec-validator` и `schemathesis`.
- `node`/`npx` — для `markdownlint-cli`; первый запуск качает пакет
  (несколько секунд), дальше npx кеширует.

Ничего из этого не нужно устанавливать вручную для CI — на
`ubuntu-latest` есть всё, кроме python-пакетов, которые ставит сама
цель `venv`.

Отдельно, только для `make code-quality` (не входит в `make
check`/CI — см. ниже): `ruff`/`bandit` (`pip install ruff bandit`) для
Python, `golangci-lint`/`gosec` (`go install
github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest` и
`go install github.com/securego/gosec/v2/cmd/gosec@latest`) для Go.
Для остальных языков эксперимента (Ruby/Rubocop, JS-TS/ESLint,
Scala/Scalafix, OCaml) `scripts/run-code-quality.sh` пока не
реализован — добавляется по факту, когда язык доходит до пилота.

## Быстрый старт

```bash
git clone git@github.com:argent-smith/llm-lang-experiment.git
cd llm-lang-experiment
make check
```

`make check` = `make lint` (shellcheck + markdownlint + валидация
OpenAPI-схемы) + `make test` (smoke + контрактный тест против
`acceptance/reference-impl`) — ровно то же самое, что на каждый push
гоняет `.github/workflows/acceptance.yml`.

## Цели Makefile

`make help` печатает список с однострочным описанием каждой. Ниже —
подробности и примеры для тех, где однострочника мало.

| Цель                | Пример                                                                                                                                                                                                                                                                |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make smoke`        | `make smoke PORT=18099` — против другого порта; `make smoke IMPL=path/to/impl` — против другой реализации, когда появится                                                                                                                                             |
| `make contract`     | `make contract` — первый запуск создаёт `.venv` (может занять минуту), дальше быстро                                                                                                                                                                                  |
| `make run-server`   | `make run-server PORT=9000 DATA_DIR=/tmp/mydata` — поднять сервер вручную для ручных curl-проверок, Ctrl+C останавливает и убирает контейнер                                                                                                                          |
| `make run-client`   | `make run-client ARGS="push /tmp/somedir --server http://127.0.0.1:18080"`                                                                                                                                                                                            |
| `make build`        | Форсированно пересобрать образ эталонной реализации — обычно не нужно, `run-server`/`run-client` сами пересобирают лениво по кешу                                                                                                                                     |
| `make fmt-tables`   | То же самое, что автоматически делает Claude Code hook после `Edit`/`Write` — полезно, если правите markdown не через Claude Code                                                                                                                                     |
| `make clean`        | Снести `.venv`, кеши `schemathesis`/`hypothesis`, зависшие docker compose проекты `syncbox-reference-impl-*`                                                                                                                                                          |
| `make code-quality` | `make code-quality CQ_LANG=python IMPL=/Users/<user>/work/syncbox-python` — findings в `/tmp/syncbox-code-quality-python-{quality,security}.json` (или `CQ_OUT=<префикс>`); не входит в `make check`, результат не гейтит цикл ревью тикета (CLAUDE.md, раздел «Метод») |

## Типичные проблемы

### На macOS падает `09-server-has-updated-content-after-sync`

Не баг реализации. При разработке воспроизводился баг file-sharing в
Docker Desktop (VirtioFS/gRPC-FUSE) — свежесозданный контейнер иногда
видит устаревшее содержимое bind-mounted файла сразу после записи на
хосте, воспроизводится даже голым `docker run --rm -v $DIR:$DIR alpine
cat $DIR/file`. Под текущей compose-обвязкой это не проявилось на
нескольких чистых прогонах подряд, но первопричина — в самом Docker
Desktop, не в нашем коде, так что при подозрении на повтор
ориентируйтесь на CI (Linux, никакой VM-прослойки в bind-mount), а не
на единичный локальный результат. Подробнее — в
`acceptance/reference-impl/README.md`.

### `docker: Cannot connect to the Docker daemon`

Docker Desktop не запущен. На macOS: `open -a Docker`, подождать, пока
`docker info` не начнёт отвечать без ошибки.

### `port is already allocated` / контейнер уже существует

Предыдущий прогон не почистился — например, `make run-server` был
запущен в фоне (`&`) и остановлен не через Ctrl+C, а внешним `kill` не
той цели. Убрать руками: `docker compose -f
acceptance/reference-impl/docker-compose.yml -p
syncbox-reference-impl-<port> down --remove-orphans`, или `make clean`
целиком.

### `make markdownlint` ругается на длину строк

Не должно: MD013 отключён в `.markdownlint.json` — это осознанный стиль
проекта (длинные абзацы без переноса), а не то, что нужно переписывать.
Если такие ошибки всё же появились, проверьте, что `.markdownlint.json`
не удалён и не переопределён.

## Как это соотносится с CI

`.github/workflows/acceptance.yml` на каждый push и pull request
прогоняет ровно `make check` на `ubuntu-latest` — тот же код, что и
локально, разница только в операционной системе (важно для раздела
про macOS выше). Отдельных CI-специфичных шагов, которые не
воспроизводятся локально, нет.
