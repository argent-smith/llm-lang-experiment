# Инцидент: метрика «Время (API/инфра/работа)» сломалась под Docker-in-Docker

Дата: 2026-09-02. Повод — первый канонический тикет на DinD-харнессе
(тикет 10, клиент `sync`). Поле «Время (API/инфра/работа)» в
`docs/EXPERIMENT-LOG.md` — не косметика: оно отделяет время модели от
инфраструктурного шума (загрузка образов, установка зависимостей) для
честного сравнения языков. На тикете 10 оно развалилось в двух местах,
плюс всплыла третья, отдельная регрессия перехода на DinD.

## Диагностика

Тот же Python на DooD (тикет 9) и DinD (тикет 10):

|                                     | DooD т9              | DinD т10 (iter2)    |
| ----------------------------------- | -------------------- | ------------------- |
| span транскрипта / `duration_ms`    | 358 с / 358 с = 100% | 119 с / 963 с = 12% |
| docker-команды агента в транскрипте | 10                   | 0                   |
| сумма elapsed по tool-вызовам       | 63 с (max 31 с)      | 0.4 с (max 0 с)     |
| `duration_api_ms` vs `duration_ms`  | api < total (норма)  | api > total         |

`api > total` — у всех 8 архивных прогонов тикета 10, разрыв 20–282 с
(worst — Ruby и TypeScript, шедшие сразу после сброса 429-окна).

## Поломка 1: архивный `transcript.jsonl` обрезан

`scripts/analyze-timing-breakdown.py` классифицирует инфра/работу,
разбирая BuildKit-вывод `docker compose build` из транскрипта. В
транскриптах тикета 10 этих команд нет — только начальная фаза «Read
всех файлов проекта» (у Python — 69 tool-вызовов, все `Read`, часть по
несуществующим путям). Реализация, `run-tests`, `docker compose`,
отладка — всё после — потеряно.

Причина — гонка при teardown DinD-контейнера. Прежний
`pilot-harness-entrypoint.sh` завершался `exec su-exec node claude -p …`
— claude становился PID 1. По его выходе контейнер (`--rm`) убивался
мгновенно, вместе с ещё не сброшенными на bind-mount записями
транскрипта: одноразовый `$CLAUDE_HOME_DIR` под DinD virtiofs не
успевал синхронизироваться. На DooD claude был прямой командой
контейнера, без `exec`-цепочки и фонового `dockerd` — сброс успевал.

## Поломка 2: `duration_ms` под DinD недосчитывает

Ruby т10: транскрипт (238 записей) охватывает 808 с, `duration_api_ms` =
817 с, а `duration_ms` = 535 с. То есть события сессии длятся дольше,
чем claude сам отчитался про своё время. `tool_ms_total = duration_ms −
duration_api_ms` уходит в минус, и декомпозиция (`работа = tool_ms_total
− инфра`) рассыпается.

`analyze-timing-breakdown.py` строил разбивку как остаток от
`duration_ms − duration_api_ms` (difference of two large similar
numbers — хрупко и на DooD). Под DinD ломаются ОБА слагаемых:

- `duration_ms` недосчитывает — старт вложенного `dockerd` (несколько
  секунд) плюс `docker load` базовых образов идут ДО запуска claude, из
  его self-таймера выпадают.
- `duration_api_ms` завышен. На контрольном прогоне через фикшеный
  харнесс (`cbbf82af`, агент почти не работал локально — `sync` уже был
  готов) `duration_api_ms` = 296 с при внешне замеренном
  `container_wall_ms` = 281 с: поле Claude Code на 15 с БОЛЬШЕ всего
  времени жизни контейнера. Это сумма по турнам, и под
  стримингом/очередью API она перекрывается сама с собой — не чистое
  подмножество wall-time. Значит модель-время из `result.json` нельзя
  вычитать из wall без риска ухода в минус.

## Регрессия перехода на DinD: пропал `WORKDIR /workspace`

Базовый образ `docker:27-dind` своего `WORKDIR` не задаёт, а при
переписывании `pilot-harness.Dockerfile` под DinD `WORKDIR /workspace`
из прежнего (`node:22-slim`) образа не перенесли. На
`ticket-9-dind-shakedown` и тикете 10 claude запускался из `/` и сам
доходил до `/workspace` (все прогоны сошлись, но стартовый контекст
агента отличался от тикетов 1–9). Восстановлено.

## Фикс (2026-09-02)

**A — надёжный захват транскрипта.** `pilot-harness-entrypoint.sh` не
`exec`-ает, а через EXIT-trap: после выхода claude копирует транскрипт
сессии из `~/.claude/projects/*/*.jsonl` в
`/workspace/.harness-session-transcript.jsonl` (директория пилота —
интенсивно используемый bind-mount, синхронизируется надёжно) и делает
`sync` до `--rm`-teardown. `scripts/run-pilot-ticket.sh` берёт
транскрипт оттуда, с fallback на прежний путь через `$CLAUDE_HOME_DIR`
(для архивов до фикса). Не через фоновый `&`: асинхронная команда в
POSIX sh получает stdin из `/dev/null`, а `claude -p` читает промпт со
stdin.

**B — внешний wall-clock + новая модель времени.**
`run-pilot-ticket.sh` замеряет время вокруг `docker run` сам
(`container_wall_ms`) и пишет в `<архив>/harness-timing.json` —
`analyze-timing-breakdown.py` берёт его как `wall_ms` вместо
недосчитанного `duration_ms` (для архивов без `harness-timing.json`,
т. е. DooD, остаётся `duration_ms`). Арифметика больше НЕ опирается на
`duration_api_ms`:

- `tool_wall_ms` — прямая сумма wall-time всех пар `tool_use`/`tool_result`
  из транскрипта (clean subset wall-time, неотрицательна; требует полного
  транскрипта — почин A);
- `infra_ms` — её инфраструктурная часть по прежнему классификатору
  BuildKit-вывода;
- `work_ms = tool_wall_ms − infra_ms`;
- `model_ms = wall_ms − tool_wall_ms` (генерация + стриминг + оверхед).

Все три неотрицательны по построению. На DooD совпадает со старым
методом (тикет 9, Python: `model` 294 с ≈ прежнее `api` 296 с, `work`
63 с). `duration_api_ms` остаётся в `timing-breakdown.json` справочным
полем; если оно превышает `wall_ms` — пишется `note_duration_api`.
Архивы с обрезанным или, наоборот, переросшим `duration_ms` транскриптом
(4 канонических прогона тикета 10, сделаны до почина) помечаются полем
`warning` — их разбивка недостоверна.

**C — базовые образы вне времени прогона.** `scripts/build-base-images-tar.sh`
тянет базовые образы стендов (`python:3.12-slim`, `node:22-alpine`,
`ruby:3.3-slim`, `alpine`) и сохраняет в `scripts/base-images.tar`
(гитигнорится, ~150 МБ). Он `COPY`-ится в образ харнеса и
`docker load`-ится вложенным демоном на старте — `docker compose build`
кода тикета больше не тянет базу с registry каждый прогон. Сам `pull`
выполнен один раз, при сборке образа харнеса, в `duration` прогонов не
входит. Запускать скрипт вручную: на новой машине и при смене `FROM ...`
в Dockerfile'ах пилота.

**WORKDIR /workspace** возвращён в `pilot-harness.Dockerfile`.

## Проверка

Прямыми прогонами контейнера харнеса подтверждено: (1) `claude -p`
получает промпт со stdin при EXIT-trap-схеме; (2) транскрипт
копируется в `/workspace/.harness-session-transcript.jsonl`;
(3) базовые образы видны во вложенном демоне (`docker images` — все 4);
(4) `harness-timing.json` пишется, `analyze-timing-breakdown.py` берёт
`container_wall_ms`.

E2e через фикшеный харнесс — прогон Python тикета 10 (`sync` уже был
реализован, `cbbf82af`, архив в `ticket-10-dind-timing-verify/`):
транскрипт охватывает 97% времени прогона (было 12%), `wall_ms` =
`container_wall_ms` 281 с, `model_ms` 281 с, `tool_wall_ms` 0.6 с,
отрицательных значений нет.

Уточнение 2026-09-03: этот e2e-прогон `cbbf82af` сам шёл с мёртвым
инструментом Bash (8× «No suitable shell found» в его `transcript.jsonl`
— та же регрессия перехода на Alpine, что и на канонических тикетах 10,
[docs/incidents/2026-09-03-dind-bash-missing/](../2026-09-03-dind-bash-missing/README.md)).
Поэтому «`tool_wall_ms` 0.6 с — агент почти не работал локально, верно» —
это ложная атрибуция дохлого инструмента к лёгкой нагрузке, а не
подтверждение метрики на реальной работе. Обещанного «первого
подтверждения `infra_ms > 0` под DinD на тикете 11» так и не случилось
(тикет 11 не гонялся). Новый метод разбивки валидируется только на
переигровке тикета 10 с рабочим bash — транскрипт с реальными
`docker compose build` / `run-tests` и `infra_ms > 0` без `warning`.
`analyze-timing-breakdown.py` теперь помечает `warning`, если на
полноразмерном тикете `infra_ms == 0` при почти нулевом `tool_wall_ms`
(guard от именно этой ложной атрибуции).

## Граница

Тикеты 1–9 (DooD) не затронуты — их `duration_ms` корректен, разбивка
валидна, новый метод даёт те же числа. 4 канонических прогона тикета 10
сделаны до почина: транскрипт обрезан либо `duration_ms` недосчитан,
внешнего `container_wall_ms` в архиве нет — их `timing-breakdown.json`
несёт поле `warning`, в журнале помечены «н/д (DinD, до почина timing)».
Пересчёт потребовал бы переигровки тикета 10 (решение оператора). Тикет
11 и далее — на фикшеном харнессе.

## Продолжение (2026-09-03): фикс `831f0a5` был неполным

Первая переигровка тикета 10 (Python, на харнессе с bash) снова дала
негодный архивный `transcript.jsonl` — 516 КБ **нулевых байт**. Не
обрезка (как ловил `831f0a5`), а NUL-заполнение файла правильного
размера: virtiofs Docker Desktop на macOS отдаёт хосту метаданные
файла (размер), но не блоки данных, если writeback bind-mount-копии не
завершился до `--rm` teardown. `cp` + голый `sync` в EXIT-trap от этого
не спасает — `sync` без аргумента advisory, а не fsync конкретного
файла. `analyze-timing-breakdown.py` при этом падал с `JSONDecodeError`.

Фикс (три части):

- `scripts/run-pilot-ticket.sh` — транскрипт читается из
  `$CLAUDE_HOME_DIR/projects/*.jsonl` **первым** источником (это хостовый
  bind-mount; после возврата `docker run` контейнер снесён и
  virtiofs-writeback форсирован teardown'ом — данные на хосте целиком).
  Копия в `/workspace` от entrypoint — теперь fallback. Оба кандидата
  проходят валидатор `_valid_transcript` (непустой + первая непустая
  строка парсится как JSON), NUL-файл отбраковывается.
- `scripts/pilot-harness-entrypoint.sh` — `sync <файл>` (GNU coreutils,
  fsync именно на копию) вместо голого `sync`.
- `scripts/analyze-timing-breakdown.py` — не падает на NUL/мусорном
  транскрипте: 0 валидных записей → ветка `warning`, не traceback.

Проверено на переигровке тикета 10: Python — транскрипт 184/184 валидных
JSON, читан из `$CLAUDE_HOME_DIR`; JavaScript — 166/166, `infra_ms`
2001 мс (**первое подтверждение `infra_ms > 0` под DinD** — npm install
в билде классифицировался как инфра).
