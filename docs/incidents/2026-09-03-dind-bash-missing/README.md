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

Заодно (решение оператора, тот же PR) закреплены раздражители перехода
на DinD, перечисленные в «Открытом следе» ниже:

- `scripts/pilot-harness.Dockerfile`: `FROM docker:27-dind@sha256:aa3df78e…`
  (мультиарх-индекс — CI на linux/amd64 резолвит свой child), все
  `apk`-пакеты по `=version` (Alpine 3.21.3: `bash=5.2.37-r0`,
  `nodejs=22.23.2-r0`, …). GC старых ревизий Alpine теперь роняет сборку
  явно — это лучше бесшумного дрейфа.
- Туда же — GNU `coreutils`/`findutils`/`grep`/`sed` вместо busybox:
  паритет с тикетами 1–9 (там был Debian-базис с GNU-утилитами).

### Второй слой: архивный транскрипт под DinD — NUL вместо обрезки

Первая переигровка тикета 10 (Python) снова дала негодный
`transcript.jsonl` — 516 КБ **нулевых байт**. Не обрезка (её ловил
`831f0a5`), а NUL-заполнение файла правильного размера: virtiofs Docker
Desktop на macOS отдаёт хосту метаданные (размер), но не блоки данных,
если writeback bind-mount-копии не завершился до `--rm` teardown. `cp` +
голый `sync` в EXIT-trap от этого не спасает (`sync` без аргумента —
advisory, а не fsync конкретного файла); `analyze-timing-breakdown.py`
падал на таком файле с `JSONDecodeError`.

- `scripts/run-pilot-ticket.sh`: транскрипт читается из
  `$CLAUDE_HOME_DIR/projects/*.jsonl` **первым** источником — это хостовый
  bind-mount, после возврата `docker run` контейнер снесён и
  virtiofs-writeback форсирован teardown'ом, данные на хосте целиком.
  Копия в `/workspace` от entrypoint — теперь fallback. Оба кандидата
  проходят `_valid_transcript` (непустой + первая непустая строка
  парсится как JSON), NUL-файл отбраковывается.
- `scripts/pilot-harness-entrypoint.sh`: `sync <файл>` (GNU coreutils —
  fsync именно на копию) вместо голого `sync`.
- `scripts/analyze-timing-breakdown.py`: 0 валидных записей → ветка
  `warning`, а не traceback.

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

### Переигровка тикета 10 (2026-09-03)

Baseline каждого языка — канонический код тикета 9 (`sync` отсутствует),
через `run-pilot-loop.sh` (`--contract block --tests block --smoke info`,
`--max-iters 4`).

| язык       | session    | shell-ошибок | транскрипт   | run-tests           | contract | infra_ms | исход                                             |
| ---------- | ---------- | ------------ | ------------ | ------------------- | -------- | -------- | ------------------------------------------------- |
| Python     | `73bad73f` | 0            | 184/184 JSON | 181 pytest          | 3/3      | 0        | сошлось за 1 итер.                                |
| JavaScript | `64c457c9` | 0            | 166/166 JSON | 69/69 `node --test` | 3/3      | **2001** | сошлось за 1 итер.                                |
| Ruby       | `239606a6` | 0            | 204/204 JSON | 157 examples        | 3/3      | 0        | сошлось за 1 итер.                                |
| TypeScript | —          | —            | —            | —                   | —        | —        | 529, затем 429 — переигрывается после сброса окна |

JS дал **первое подтверждение `infra_ms > 0` под DinD** (`npm install` в
билде стенда). `infra_ms` 0 у Python/Ruby — зависимости стендов
кешируются во вложенном демоне в пределах прогона. smoke локально 4/13 у
всех — задокументированный флак Docker Desktop (протухший client-образ),
не код; CI — авторитет.

## Граница

- Тикеты 1–9 (DooD, `node:22-slim`) не затронуты — bash был в базовом
  образе, транскрипты чисты (тикеты 8 и 9 проверены `grep`-ом: 0 ошибок
  во всех 4 языках).
- Тикеты 10 и `ticket-10-dind-timing-verify` (`cbbf82af`) аннулированы
  как данные (строки `docs/EXPERIMENT-LOG.md` 109–112, `NOTE.md` архива
  `cbbf82af`). `docs/pilot-runs/manifest.json` — `canonical_ticket`
  четырёх языков доклада откачен `10 → 9` до завершения переигровки;
  `pilot-gates.yml` читает поле динамически, гоняет тикет 9. Переигровки
  Python/JS/Ruby приняты (строки лога от 2026-09-03); после переигровки
  TypeScript — вернуть `canonical_ticket` на `10` и перенацелить
  `manifest.json` на новые сессии.

## Открытый след

Пиннинг базового образа и `apk`-пакетов — сделан (см. «Фикс» выше).
Остаётся необязательное: писать `harness-env.json` с
`docker/node/npm/bash --version` в архив каждого прогона, чтобы дрейф был
виден постфактум даже при смене пина — отдельное решение, не блокирует.
