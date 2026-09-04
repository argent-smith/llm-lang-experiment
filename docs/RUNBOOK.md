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
(`scripts/pilot-harness.Dockerfile` + `scripts/pilot-harness-entrypoint.sh`,
тег `pilot-harness:latest`) собирается автоматически при каждом вызове
(кеш слоёв BuildKit делает это дёшево) — руками собирать не нужно.
Сам вызов `claude -p` идёт не на хосте, а внутри этого контейнера, с
единственной примонтированной с хоста директорией пилота — почему это
обязательно, а не просто внутренние настройки Claude Code, см.
[docs/incidents/2026-08-21-write-tool-sandbox-escape/](incidents/2026-08-21-write-tool-sandbox-escape/README.md).
С 2026-09-01 контейнер харнеса запускается с `--privileged` и поднимает
внутри собственный `dockerd` (Docker-in-Docker): `docker compose` кода
тикета идёт в этот внутренний демон, а не в хостовый, у которого агент
через проброшенный сокет мог примонтировать произвольный хостовый путь
([docs/incidents/2026-09-01-dood-host-fs-reachable/](incidents/2026-09-01-dood-host-fs-reachable/README.md)).
Внутренний демон пуст на старте каждого прогона; базовые образы стендов
предзапечены в образ харнеса из `scripts/base-images.tar` — этот файл
гитигнорится и генерится вручную скриптом `scripts/build-base-images-tar.sh`:
запустить один раз на новой машине и после смены базового образа в
Dockerfile'ах пилота (`FROM ...`). Без файла сборка не падает, но
прогоны тянут базу с registry (медленнее, метрика времени зашумлена —
см. [docs/incidents/2026-09-02-dind-timing-broken/](incidents/2026-09-02-dind-timing-broken/README.md)).
`scripts/run-pilot-ticket.sh` кладёт рядом с `result.json` ещё
`harness-timing.json` с внешним замером времени `docker run`
(`container_wall_ms`) — под DinD `duration_ms` из `result.json`
недосчитывает.

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

| Цель                | Пример                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make smoke`        | `make smoke PORT=18099` — против другого порта; `make smoke IMPL=path/to/impl` — против другой реализации, когда появится                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `make contract`     | `make contract` — первый запуск создаёт `.venv` (может занять минуту), дальше быстро                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `make run-server`   | `make run-server PORT=9000 DATA_DIR=/tmp/mydata` — поднять сервер вручную для ручных curl-проверок, Ctrl+C останавливает и убирает контейнер                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `make run-client`   | `make run-client ARGS="push /tmp/somedir --server http://127.0.0.1:18080"`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `make build`        | Форсированно пересобрать образ эталонной реализации — обычно не нужно, `run-server`/`run-client` сами пересобирают лениво по кешу                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `make fmt-tables`   | То же самое, что автоматически делает Claude Code hook после `Edit`/`Write` — полезно, если правите markdown не через Claude Code                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `make clean`        | Снести `.venv`, кеши `schemathesis`/`hypothesis`, зависшие docker compose проекты `syncbox-reference-impl-*`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `make pilot-ticket` | Один вызов `claude -p` по тикету, без гейтов и итераций: `make pilot-ticket PILOT_DIR=pilot-runs-live/python PROMPT=pilot-runs-live/python/.ticket-1-prompt.txt OUT=/tmp/ticket-1-result` — реализация + автоматическая архивация в `docs/pilot-runs/`; сами промпты тикетов — в `docs/pilot-runs/<язык>/ticket-<N>/*/prompt.txt` уже прошедших попыток                                                                                                                                                                                                                                     |
| `make pilot-loop`   | Авто-итерирующий луп по тикету (с 2026-08-31 — основной способ, см. `CLAUDE.md`, «Метод», п. 3): `make pilot-loop PILOT_DIR=pilot-runs-live/python PROMPT=pilot-runs-live/python/.ticket-8-prompt.txt OUT=/tmp/ticket-8`. `claude -p` → `run-gates.sh` (tests/smoke/contract) → при провале блокирующего гейта авто-фикс-промпт → `claude -p` → … до сходимости или `--max-iters` (по умолч. 4). Доп. флаги — через `LOOP_ARGS="--max-iters 3 --smoke skip"`. Сводка по итерациям — `<OUT>.loop.json`. Каждая итерация архивируется отдельной session-директорией под тем же `ticket-<TAG>` |
| `make gates`        | Три acceptance-гейта против снапшота реализации, без `claude -p`: `make gates PILOT_DIR=pilot-runs-live/python OUT=/tmp/gates`. Режимы — через `GATE_ARGS="--contract block --smoke info --tests block"`. Пишет `<OUT>/gates.json`. Контракт поднимает сервер с `/data` на tmpfs (не bind-mount) — иначе virtiofs Docker Desktop делает прогон недетерминированным, см. `docs/incidents/2026-08-31-contract-gate-tooling/`                                                                                                                                                                  |
| `make pilot-replay` | Кампания перепрогона всего бэклога на стабилизированном воркфлоу (авто-луп + DinD + все гейты `block`) с чекпойнтом и митигацией лимита 429/529: `make pilot-replay REPLAY_ARGS="--dry-run"`. См. раздел «Кампания перепрогона пилота» ниже                                                                                                                                                                                                                                                                                                                                                 |

Обёртки в директории пилота: `run-server`, `run-client`, `run-tests`
(последняя — с 2026-08-31, гоняет штатные тесты реализации в Docker,
`docs/SYNCBOX-SPEC.md` → «Критерии приёмки»). Для пилотов тикетов 1–12
(py/js/ts/ruby) `run-tests` дописан руками под гейт; агент пишет свой с
тикета 8+.

## Кампания перепрогона пилота

`scripts/run-pilot-replay.sh` (`make pilot-replay REPLAY_ARGS="..."`).

### Зачем

Единой конфигурации у бэклога пока нет (см. раздел «Сопоставимость:
метод дрейфовал» в `docs/PILOT-COMPARISON-talk-languages.md`): тикеты
1–7 прошли ручным циклом на Docker-out-of-Docker, 8–9 — скриптованным
лупом, но всё ещё DooD и до фикса метрики времени, и только 10–11 — на
целевой конфигурации (DinD, авто-луп `run-pilot-loop.sh`, все гейты
`block`). Кампания перепрогоняет весь бэклог под конфигурацией 10–11,
чтобы страты S1/S2/S3 в сравнительном отчёте схлопнулись в одну.

### Охват первой кампании

Четыре языка доклада (`in_talk: true`) × тикеты 1–11 = 44 ячейки
(язык × тикет). Go/Scala/OCaml (`in_talk: false`) — отдельной кампанией
позже (`--languages "go scala ocaml" --tickets "1 2 3"`).

### Что фиксируется

- Харнесс: DinD, `run-pilot-ticket.sh`, образ `pilot-harness:latest`,
  базовые образы предзапечены (`scripts/build-base-images-tar.sh` один
  раз до старта).
- Цикл: `run-pilot-loop.sh --max-iters 4`.
- Модель/effort: `claude-sonnet-5` / `xhigh` (зашито в
  `run-pilot-ticket.sh`).
- Гейты: `--tests block --contract block --smoke block`. **smoke теперь
  `block`** (не `info`, как на тикетах 8–9): тикеты 8–11 сделаны, шаги
  смока 08–11 больше не падают by design. До кампании проверить, что
  reference-impl проходит `make smoke` 13/13 — то есть гнать кампанию на
  Linux-хосте, не на macOS (там флак file-sharing, см. «Типичные
  проблемы»).
- Промпт ячейки — verbatim initial-промпт тикета из архива
  `docs/pilot-runs/<lang>/ticket-<N>/<канон-сессия>/prompt.txt` (канон
  из `manifest.json`; если там фикс-промпт — берётся любая сессия
  тикета с initial-промптом). Проверить резолвинг до старта:
  `make pilot-replay REPLAY_ARGS="--check-prompts"`.

### Порядок

Language-major, тикеты строго 1→11 внутри языка. У каждого языка своя
персистентная pilot-директория `pilot-runs-live/<lang>/`, которая **не
вайпается между его тикетами** (тикет N строится на коде N−1). Перед
первым тикетом языка директория должна быть пуста — иначе скрипт
откажется (или `--force-clean`, чтобы очистить).

### Митигация лимита 429 / 529

Оконный лимит использования (не хаотичный per-request rate limit): при
нём `claude -p` отдаёт `is_error: true` + `api_error_status: 429|529`,
точное время сброса — текстом в `result.json` → `.result`. Ждать
backoff бессмысленно, только явную паузу до сброса (CLAUDE.md, «Сначала
пилот», п. 3).

`run-pilot-loop.sh` теперь выделяет этот случай отдельным исходом
(`сдался (rate-limit <код> …)` + поле `api_error_status` в `.loop.json`).
Оркестратор на него:

1. парсит время сброса из последнего `.iterK.json` (`replay-checkpoint.py
   parse-reset`); если не распарсилось — фиксированная пауза
   `--fixed-pause-sec` (1 ч);
2. пишет `pause`-запись в чекпойнт (вне учёта времени и итераций —
   пауза между вызовами `claude -p` в «Время» не входит, CLAUDE.md,
   «Лог»);
3. спит до сброса + `--pause-margin-sec` (5 мин), но не дольше
   `--max-pause-sec` (6 ч) за одну паузу;
4. повторяет ту же ячейку с итерации 1 (свежая сессия; токены
   до-429-й итерации логируются, но пилотной итерацией не считаются);
5. предел `--max-429-retries` (3) пауз-ретраев на ячейку, потом жёсткий
   стоп с чистым чекпойнтом — продолжить после сброса окна:
   `--resume`.

Не-429 инфра-фейл и «харнесс неисправен» (нет bash в образе) —
жёсткий стоп без ретрая: чинить, не повторять.

### Как запускать

```bash
# 0. предзапечь базовые образы (один раз на машине)
scripts/build-base-images-tar.sh

# 1. проверить резолвинг промптов по всем 44 ячейкам
make pilot-replay REPLAY_ARGS="--check-prompts"

# 2. план ячеек
make pilot-replay REPLAY_ARGS="--dry-run"

# 3. кампания (правильно — сразу после известного сброса окна)
make pilot-replay REPLAY_ARGS="--force-clean"

# 4. после Ctrl-C / стопа по 429 / падения — продолжить
make pilot-replay REPLAY_ARGS="--resume --out-root pilot-runs-live/.replay-<TS>"
```

Исход: `0` — все ячейки сошлись; `1` — жёсткий стоп (429 сверх лимита,
не-429 инфра, харнесс); `2` — дошло до конца, но часть ячеек не сошлась
(`spec-giveup` / `no-converge`) — данные записаны, нужен разбор.

### После кампании

Скрипт `manifest.json` не трогает. Вручную (как для тикета 10):

1. По каждой новой сошедшейся сессии —
   `scripts/verify-replay.py docs/pilot-runs/<lang>/ticket-<N>/<session>`.
2. `docs/pilot-runs/manifest.json`: `languages.<lang>.tickets.<N>` →
   новый путь; старые директории оставить, добавить пометку
   `_ticket_<N>_replayed_<TS>`.
3. Пересобрать `docs/PILOT-COMPARISON-talk-languages.md` (страта теперь
   одна), дописать строки в `docs/EXPERIMENT-LOG.md`, обновить буллет
   «Пилот с этим согласуется» в
   `docs/MARKET-PREVALENCE-experiment-languages.md`, если отношение
   TS↔Python поедет.

### Бюджет

Из текущей сетки отчёта: сумма тикетов 1–11 на язык — Python ~$15,
JavaScript ~$14, TypeScript ~$19, Ruby ~$22 за один чистый проход.
С ре-итерациями лупа и потерянными до-429 партиалами — ×1.5–2, итого
**$105–140** на четыре языка. Календарно с паузами по окнам 429 —
кампания на 2–3 дня.

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

### `pilot-harness-entrypoint: вложенный dockerd не поднялся за 60 с`

Docker-in-Docker внутри контейнера харнеса не стартовал. Обычные
причины: контейнер запущен без `--privileged` (в `run-pilot-ticket.sh`
он есть — проверить, если запускался руками); в VM Docker Desktop не
инициализировался overlay2 поверх overlay2 (в скрипте под
`/var/lib/docker` заведён анонимный том — проверить, что флаг
`-v /var/lib/docker` на месте); лог самого демона печатается в stderr
прогона следом за сообщением. Быстрая проверка образа отдельно:
`docker run --rm --privileged -v /var/lib/docker --entrypoint
/usr/local/bin/pilot-harness-entrypoint.sh pilot-harness:latest docker info`.

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
