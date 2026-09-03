# Инцидент: в образе харнеса нет bash — инструмент Bash агента мёртв с тикета 10

Дата обнаружения: 2026-09-03. Регрессия внесена 2026-09-01 (коммит
`5917b5e`, переход харнеса на Docker-in-Docker). Найдено при разборе
метрики времени тикета 10, не проявилось как падение гейта — наоборот,
все четыре канонических прогона тикета 10 логированы «сошлось».

## Severity

Высокая для данных, средняя для инфраструктуры. Эксплуатации-влияния на
изоляцию нет. Но: данные тикета 10 по всем четырём языкам доклада
(Python/JS/TS/Ruby) собраны деградированным агентом и несравнимы с
тикетами 1–9; регрессия прожила незамеченной один полный тикет, потому
что ни авто-луп, ни host-side гейты не проверяют, что инструментарий
агента внутри сессии вообще работает.

## Что произошло

`claude -p` внутри контейнера харнеса вызывал инструмент Bash, и каждый
вызов возвращал:

```text
No suitable shell found. Claude CLI requires a Posix shell environment.
Please ensure you have a valid shell installed and the SHELL environment
variable set.
```

Проверка по архивным транскриптам (`grep -c "No suitable shell found"`):

| тикет                              | харнесс        | Python | JS  | TS | Ruby |
| ---------------------------------- | -------------- | ------ | --- | -- | ---- |
| 9 (последний DooD)                 | node:22-slim   | 0      | 0   | 0  | 0    |
| 10 (первый DinD)                   | docker:27-dind | 3      | 5–7 | 5  | 14   |
| 10-dind-timing-verify (`cbbf82af`) | docker:27-dind | 8      | —   | —  | —    |

Агент, лишённый Bash, писал реализацию `client/sync.*` вслепую через
Read/Write/Edit, ни разу не запускал ни `docker compose build`, ни
`run-tests`, ни `run-server`/`run-client`, ни `curl`-проверки. На тикете
10 (JS) агент это явно распознал и в `result` написал, что не может
починить окружение сам. На остальных — просто отработал по сокращённой
траектории и остановился.

## Диагностика

Причина одна. Коммит `5917b5e` сменил базовый образ харнеса с
Debian-based `node:22-slim` на Alpine-based `docker:27-dind` и перенёс
строку установки пакетов один в один:

```dockerfile
RUN apk add --no-cache nodejs npm su-exec curl ca-certificates git
```

— без `bash`. `node:22-slim` нёс `/bin/bash` в самом базовом образе,
поэтому инструмент Bash работал — по счастливой случайности, а не
потому, что харнесс это обеспечивал. Alpine несёт только busybox
`/bin/sh` (`/bin/sh -> /bin/busybox`), bash и zsh отсутствуют.

Детектор shell в `claude-code` 2.1.238 (`nIn()` в `claude.exe`,
подтверждено `strings` + разбором) строит список кандидатов
исключительно как `["zsh","bash"] × ["/bin","/usr/bin","/usr/local/bin",
"/opt/homebrew/bin"]`, плюс `which zsh`/`which bash`, плюс
`$CLAUDE_CODE_SHELL`/`$SHELL` — но только если значение содержит
подстроку `bash` или `zsh`. Каждый кандидат обязан пройти
`fs.accessSync(p, X_OK)` либо `p --version` == 0. Ни один путь,
оканчивающийся на `sh` (не `bash`/`zsh`), кандидатом не становится
никогда. Отсюда следствия, подтверждённые прямыми прогонами контейнера:

- `ENV SHELL=/bin/sh` **не помогает** — не проходит гейт
  `value.includes("bash") || value.includes("zsh")`, в список кандидатов
  не попадает, а busybox `/bin/sh` не рассматривается по построению.
- `apk add bash` при **не** выставленном `$SHELL` — **достаточно**:
  `/bin/bash` (GNU bash 5.2, `apk info -L bash` → `bin/bash`) —
  захардкоженный кандидат, проходит `X_OK`.

`su-exec node "$@"` execает напрямую, без login-shell, и не выставляет
ни `SHELL`, ни `USER`, ни `LOGNAME` — переживает только `HOME` (его
явно экспортирует entrypoint). Login-shell пользователя `node` в
`/etc/passwd` (`adduser -D` ставит `/bin/sh`) роли не играет:
`claude-code` спаунит найденный по абсолютному пути shell для стартового
snapshot и в passwd не заглядывает.

## Почему регрессия прожила целый тикет

Критерий «сошлось» в `scripts/run-pilot-loop.sh` — это `claude_rc == 0
&& is_error != true && блокирующие гейты зелены`. Ни транскрипт, ни
`result` не проверяются на систематически падающий инструмент агента.
`scripts/run-gates.sh` целиком идёт на хосте (хостовый Docker Desktop,
хостовый `schemathesis`, хостовые `curl`/`perl`) против **файлов**,
которые агент произвёл, — мёртвый инструмент Bash внутри сессии оттуда
не виден. Прогон, где агент прямым текстом пишет, что ничего не
реализовал, логируется `subtype: success, terminal_reason: completed`.

## Фикс (2026-09-03)

- `scripts/pilot-harness.Dockerfile`: `bash` добавлен в строку
  `apk add`; `ENV SHELL=/bin/bash` — детерминированно и как страховка
  подпроцессам агента. Механизм фикса — сам пакет bash; `ENV SHELL` —
  «пояс и подтяжки».
- `scripts/pilot-harness-entrypoint.sh`: жёсткий guard
  `command -v bash || exit 1` сразу после `set -eu` (до регистрации
  `trap _finish EXIT`) — повтор этой регрессии теперь роняет контейнер, а
  не логируется «сошлось». Плюс `export SHELL=/bin/bash USER=node
  LOGNAME=node` рядом с `export HOME` — для ticket-side git/тулинга.
- `scripts/run-pilot-loop.sh`: после проверки `claude_rc`/`is_error` —
  ассерт на `"No suitable shell found"` в транскрипте прогона. При
  срабатывании: исход «сдался (харнесс неисправен…)», в `<out>.loop.json`
  ставится `"harness_invalid": true`, итерация не засчитывается.
- `scripts/analyze-timing-breakdown.py`: `warning`, если на
  полноразмерном тикете (`wall_ms > 120 с`) `infra_ms == 0` при
  `tool_wall_ms < 20 с` — эвристика «агент не выполнил ни одной
  build/test-команды». Post-`831f0a5` полный, но «пустой» транскрипт
  раньше не помечался никак.
- `docs/incidents/2026-09-02-dind-timing-broken/README.md`: раздел
  «Проверка» помечен — e2e-прогон `cbbf82af`, которым валидировали почин
  метрики, сам шёл с мёртвым bash.

`scripts/run-pilot-ticket.sh` пересобирает `pilot-harness:latest` на
каждый вызов, кеш слоёв BuildKit — правка `apk add` инвалидирует слой,
`bash` подхватывается на следующей переигровке автоматически.
`base-images.tar` не затронут (ни один `FROM` языковых стендов не
менялся) — пересобирать `scripts/build-base-images-tar.sh` не нужно.

## Проверка

Прямыми прогонами контейнера подтверждено:

- `docker run --rm --entrypoint sh pilot-harness:latest -c 'command -v
  bash; bash --version'` → `/bin/bash`, GNU bash 5.2.x.
- e2e: один дешёвый `claude -p` через реальный entrypoint, промпт
  «выполни через Bash: `echo MARKER`» → в транскрипте есть пара
  `tool_use`/`tool_result` Bash, `MARKER` в выводе, ноль «No suitable
  shell found», `is_error == false`, создан
  `~/.claude/shell-snapshots/snapshot-bash-*.sh`.
- guard: `mv /bin/bash …; pilot-harness-entrypoint.sh true` → печатает
  строку FATAL, ненулевой rc.
- `run-pilot-loop.sh`-ассерт: против копии старого сломанного архива
  тикета 10 → исход «харнесс неисправен», `harness_invalid: true`.

## Граница

- Тикеты 1–9 (DooD, `node:22-slim`) не затронуты — bash был в базовом
  образе, транскрипты чисты (тикет 9 проверен: 0 ошибок).
- Тикет 8 — первый тикет скриптованного авто-лупа, шёл на границе
  DooD/DinD; отдельно проверить `grep`-ом на «No suitable shell found»
  перед тем, как считать его данные валидными.
- Тикеты 10 и `ticket-10-dind-timing-verify` (`cbbf82af`) —
  недействительны как данные: переиграть тикет 10 для четырёх языков
  доклада на образе с bash, затем перенацелить `docs/pilot-runs/manifest.json`
  и переписать строки `docs/EXPERIMENT-LOG.md` 109–112 (исход = регрессия
  харнесса, не только текущая пометка «н/д (DinD, до почина timing)»).
  Решение по форме (аннулировать строки / переигровка) — за оператором.

## Открытый след

Переход DooD→DinD размножил незапиненные части сборки харнеса:
`FROM docker:27-dind` — подвижный тег, пакеты `apk` ничем не
зафиксированы, тулчейн Node для JS/TS уехал glibc→musl. Методика в
остальном пинит всё (ID модели, версию `claude-code`, `schemathesis`,
`--effort`). Отдельное решение: пинить базовый образ по digest и пакеты
по версии — либо писать `harness-env.json` с `docker/node/npm/bash
--version` в архив каждого прогона, чтобы дрейф был виден постфактум.
