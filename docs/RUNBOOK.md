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

Code security (bandit/gosec) пробовали и убрали 2026-08-20 — см.
`docs/PILOT-COMPARISON-python-go.md`, раздел «Code security
(исключено)».

### Пилотный харнес (Docker)

Отдельно, для `make pilot-ticket`/`scripts/run-pilot-ticket.sh`:
`scripts/pilot-harness.env` с `CLAUDE_CODE_OAUTH_TOKEN` (шаблон и
инструкция получения — `scripts/pilot-harness.env.example`; сам файл
гитигнорится, реальный токен в него не коммитится). Образ харнеса
(`scripts/pilot-harness.Dockerfile`, тег `pilot-harness:latest`)
собирается автоматически при первом вызове и пересобирается, если
Dockerfile правился после последней сборки — руками собирать не нужно.
Сам вызов `claude -p` идёт не на хосте, а внутри этого контейнера, с
единственной примонтированной директорией пилота — почему это
обязательно, а не просто внутренние настройки Claude Code, см.
[docs/incidents/2026-08-21-write-tool-sandbox-escape/](incidents/2026-08-21-write-tool-sandbox-escape/README.md).

Директории пилотных проектов (`PILOT_DIR`) конвенционально живут в
`pilot-runs-live/<язык>/` в корне этого репозитория (гитигнорится) — не
вне репозитория и не как соседи `llm-lang-experiment` на хосте, как
было в более ранней ревизии проекта: та раскладка была нужна только под
внутреннюю файловую песочницу Claude Code (`sandbox.filesystem`),
которая с переходом на Docker-обвязку больше не используется (см. выше)
— границу изоляции теперь задаёт исключительно то, что примонтировано в
контейнер, а не расположение директории на хосте. `pilot-runs-live/`
не coммитится — постоянный, воспроизводимый архив каждой попытки
(промпт, спецификация, результат, код) уже ведётся отдельно в
`docs/pilot-runs/` (см. `docs/pilot-runs/README.md`).

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

| Цель                | Пример                                                                                                                                                                                                                                                                                                                                                        |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make smoke`        | `make smoke PORT=18099` — против другого порта; `make smoke IMPL=path/to/impl` — против другой реализации, когда появится                                                                                                                                                                                                                                     |
| `make contract`     | `make contract` — первый запуск создаёт `.venv` (может занять минуту), дальше быстро                                                                                                                                                                                                                                                                          |
| `make run-server`   | `make run-server PORT=9000 DATA_DIR=/tmp/mydata` — поднять сервер вручную для ручных curl-проверок, Ctrl+C останавливает и убирает контейнер                                                                                                                                                                                                                  |
| `make run-client`   | `make run-client ARGS="push /tmp/somedir --server http://127.0.0.1:18080"`                                                                                                                                                                                                                                                                                    |
| `make build`        | Форсированно пересобрать образ эталонной реализации — обычно не нужно, `run-server`/`run-client` сами пересобирают лениво по кешу                                                                                                                                                                                                                             |
| `make fmt-tables`   | То же самое, что автоматически делает Claude Code hook после `Edit`/`Write` — полезно, если правите markdown не через Claude Code                                                                                                                                                                                                                             |
| `make clean`        | Снести `.venv`, кеши `schemathesis`/`hypothesis`, зависшие docker compose проекты `syncbox-reference-impl-*`                                                                                                                                                                                                                                                  |
| `make pilot-ticket` | Воспроизвести один тикет пилота целиком (не только код-стенд): `make pilot-ticket PILOT_DIR=pilot-runs-live/python PROMPT=pilot-runs-live/python/.ticket-1-prompt.txt OUT=/tmp/ticket-1-result` — реализация + автоматическая архивация в `docs/pilot-runs/`; сами промпты тикетов — в `docs/pilot-runs/<язык>/ticket-<N>/*/prompt.txt` уже прошедших попыток |

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

### `Unable to find image 'pilot-harness:latest' locally` сразу после сборки

Docker Desktop с containerd image store (включён по умолчанию) не
тегирует локально образ, экспортированный `docker build` с
attestation-манифестом — сборка рапортует «naming to ... done», но
`docker images` образ не находит. `scripts/run-pilot-ticket.sh` уже
собирает образ харнеса с `--provenance=false --sbom=false`, что это
чинит; если находка повторилась на образе, собранном руками —
добавить те же флаги.

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
