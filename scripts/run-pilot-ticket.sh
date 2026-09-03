#!/usr/bin/env bash
# Запускает один тикет через Claude Code headless — сам вызов `claude -p`
# идёт не на хосте, а внутри Docker-контейнера харнеса
# (scripts/pilot-harness.Dockerfile), с примонтированной директорией
# пилота как /workspace и больше ничем.
#
# Зачем контейнер, а не только внутренние настройки Claude Code: первый
# же реальный прогон (тикет 1, Python, 2026-08-19) показал
# 100%-воспроизводимую утечку — агент прочитал `acceptance/reference-impl`
# этого мета-репозитория и скопировал оттуда решения. Фикс первого
# раунда (`--safe-mode` + `sandbox.filesystem.denyRead/allowRead` через
# `--settings`) закрыл её, но дальнейший аудит (2026-08-21) показал, что
# граница была иллюзорной для инструментов Read/Write: Read внутри
# Claude Code игнорирует `denyRead` целиком (управляется только системой
# разрешений, которую `--dangerously-skip-permissions` отключает
# полностью), а Write вообще не поддерживает ограничение по пути ни в
# каком режиме — подтверждено трижды эмпирически и документацией
# permissions.md. Единственный проверенный барьер, который агент не
# может обойти изнутри, — внешняя, обеспечиваемая ядром ОС изоляция
# контейнера: если директория не примонтирована, её физически нет в
# файловой системе процесса, независимо от того, что говорят внутренние
# настройки Claude Code. Подробный разбор:
# docs/incidents/2026-08-19-python-ticket1-contamination/ (первый раунд)
# и docs/incidents/2026-08-21-write-tool-sandbox-escape/ (второй раунд,
# Docker-обвязка).
#
# Внутренние sandbox.filesystem/permissions настройки Claude Code
# сознательно не используются для этого вызова — внутри контейнера,
# где смонтирован только /workspace, ограничивать больше нечего:
# соседних языковых директорий и самого мета-репозитория в файловой
# системе процесса просто не существует. `--safe-mode` оставлен как
# дешёвая защита на случай, если в образ харнеса когда-нибудь попадёт
# собственный CLAUDE.md/хуки — не потому, что сейчас есть что отключать.
#
# Docker-IN-Docker (переход 2026-09-01, было Docker-out-of-Docker с
# пробросом хостового /var/run/docker.sock). Внутри харнеса поднимается
# собственный dockerd (см. pilot-harness-entrypoint.sh, нужен
# --privileged на `docker run` ниже); `docker compose` агента бьёт в
# него. Его файловая система — оверлей контейнера харнеса, хостовых
# /private/tmp и /Users в ней нет, поэтому агент физически не может их
# примонтировать в контейнер тикета. Это закрыло сразу три прежних
# канала DooD:
#   - `run-client status /tmp` -> bind-mount хостового /private/tmp
#     (найдено на тикете 9, Ruby — docs/incidents/2026-09-01-dood-host-fs-reachable/);
#   - `docker images`/`docker ps` показывали образы/контейнеры эталонной
#     реализации и прошлых прогонов (агент видел, что чужие прогоны
#     существуют);
#   - `docker inspect` своего же контейнера харнеса отдавал host-side
#     путь bind-mount'а с именем мета-репозитория `llm-lang-experiment`
#     (docs/incidents/2026-08-26-docker-inspect-hostpath-leak/).
# Внутренний демон про всё это ничего не знает: он пуст на старте
# каждого прогона (`/var/lib/docker` — анонимный том, `--rm` сносит
# его), не видит хостовых образов и не знает про контейнер харнеса.
# Поэтому блок чистки хостового демона от `syncbox*`/`workspace-*` —
# убран: чистить больше нечего и негде.
#
# Использование:
#   scripts/run-pilot-ticket.sh <pilot-dir> <prompt-file> <output-prefix>
#
# Предпосылка: scripts/pilot-harness.env с CLAUDE_CODE_OAUTH_TOKEN (см.
# scripts/pilot-harness.env.example). Образ pilot-harness:latest
# собирается на каждый вызов (кеш слоёв BuildKit делает это дёшево при
# отсутствии изменений в Dockerfile).
#
# Пишет:
#   <output-prefix>.json        — результат --output-format json
#   <output-prefix>.stderr.log  — stderr прогона
#   docs/pilot-runs/<язык>/ticket-<N>/<session_id>/ — архивная копия
#     промпта, спецификации/схемы, результата, полного JSONL-транскрипта
#     сессии и кода (для peer review, см. docs/pilot-runs/README.md);
#     <язык> и <N> определяются по именам <pilot-dir> и <prompt-file>.

set -euo pipefail

PILOT_DIR="${1:?Использование: run-pilot-ticket.sh <pilot-dir> <prompt-file> <output-prefix>}"
PROMPT_FILE="${2:?Использование: run-pilot-ticket.sh <pilot-dir> <prompt-file> <output-prefix>}"
OUTPUT_PREFIX="${3:?Использование: run-pilot-ticket.sh <pilot-dir> <prompt-file> <output-prefix>}"

PILOT_DIR="$(cd "$PILOT_DIR" && pwd)"
PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Свежая копия спецификации/схемы в директорию пилота перед каждым
# вызовом — не разовая копия при создании проекта. Разбор находки:
# копия, сделанная один раз 2026-08-19 до финального скраба
# docs/SYNCBOX-SPEC.md, молча разошлась с мета-репозиторием и оба
# прогона тикета 1/тикета 2 читали устаревший текст (ещё называвший
# все шесть языков и `acceptance/smoke.sh`/`acceptance/contract-test.sh`
# по именам) — см. docs/incidents/2026-08-19-python-ticket1-contamination/.
cp "$REPO_ROOT/docs/SYNCBOX-SPEC.md" "$PILOT_DIR/SYNCBOX-SPEC.md"
cp "$REPO_ROOT/docs/syncbox-openapi.yaml" "$PILOT_DIR/syncbox-openapi.yaml"

ENV_FILE="$REPO_ROOT/scripts/pilot-harness.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "run-pilot-ticket.sh: нет $ENV_FILE — см. scripts/pilot-harness.env.example (нужен CLAUDE_CODE_OAUTH_TOKEN)" >&2
  exit 1
fi

# Имя без префикса "syncbox" — историческое: прежний блок чистки
# хостового демона сносил всё "syncbox*", и образ харнеса, названный
# так же, исчезал сразу после сборки. Чистки больше нет (Docker-in-
# Docker, см. шапку), но имя оставлено как есть — на него завязаны
# .github/workflows и docs.
HARNESS_IMAGE="pilot-harness:latest"
HARNESS_DOCKERFILE="$REPO_ROOT/scripts/pilot-harness.Dockerfile"
# Собирается на каждый вызов, без ручной проверки "нужна ли пересборка"
# — кеш слоёв BuildKit сам решает, что переиспользовать, и при полном
# кеш-хите не тратит заметного времени. Ручная проверка по mtime
# Dockerfile vs `docker image inspect .Created` была ненадёжной:
# BuildKit при полном кеш-хите не меняет `Created` образа (переиспользует
# тот же контент), так что после любой правки Dockerfile постфактум
# `Created` навсегда остаётся "старше" — проверка считала бы пересборку
# нужной на каждом вызове и всё равно не экономила ничего, только
# усложняла код.
#
# --provenance=false/--sbom=false: без них Docker Desktop (containerd
# image store, включён по умолчанию) экспортирует attestation-манифест
# вместе с образом и не может протегировать результат под обычным
# именем — `docker build` рапортует "naming to ... done", но `docker
# images`/`docker run` затем не находят образ вообще (воспроизведено
# эмпирически на этом хосте). Не специфика конкретно этого образа —
# общий эффект containerd-стора с buildx, для локальных однократных
# сборок provenance/SBOM не несут пользы.
docker build --provenance=false --sbom=false -t "$HARNESS_IMAGE" -f "$HARNESS_DOCKERFILE" "$REPO_ROOT/scripts" >&2

# Прежний блок чистки хостового Docker-демона от ресурсов `syncbox*` /
# `workspace-*` (эталонная реализация, прошлые прогоны) убран вместе с
# переходом на Docker-in-Docker: `docker compose` агента больше не
# ходит в хостовый демон, а внутренний демон харнеса пуст на старте
# каждого прогона (`/var/lib/docker` — анонимный том, `--rm` его сносит).
# Чистить нечего и негде. См. шапку файла и
# docs/incidents/2026-09-01-dood-host-fs-reachable/.

# --permission-mode dontAsk молча (и, по наблюдению, непредсказуемо)
# отклоняет Edit/Write без TTY — не покрытые allow-правилом вызовы
# инструментов при dontAsk в headless-режиме отклоняются по умолчанию,
# а не разрешаются. Один прогон тикета 2 (2026-08-20) вышел success
# кодом 0, не внеся ни одной правки — агент прямым текстом сообщил,
# что Edit/Write отклонены системой разрешений. --dangerously-skip-permissions
# снимает проверки разрешений целиком — решение осознанно принято поверх
# уже существующей границы безопасности, теперь обеспечиваемой
# контейнером (см. заголовок файла), не вместо неё: даже с полностью
# снятыми внутренними проверками агент физически не видит ничего, кроме
# /workspace и своего же вложенного dockerd (у которого хостовой ФС
# нет).
#
# -v "$PILOT_DIR:/workspace:rw" — единственная примонтированная с хоста
# директория с кодом; --privileged нужен вложенному dockerd (см.
# pilot-harness-entrypoint.sh; Docker-изоляция кода тикета — «Docker-
# изоляция» в docs/SYNCBOX-SPEC.md, теперь через внутренний демон, не
# хостовый сокет); -v /var/lib/docker — анонимный том под внутренний
# демон (иначе overlay2 поверх overlay2 в VM Docker Desktop не
# инициализируется), `--rm` сносит его вместе с контейнером, поэтому
# демон каждого прогона пуст; --env-file передаёт CLAUDE_CODE_OAUTH_TOKEN,
# не ANTHROPIC_API_KEY (см. CLAUDE.md, раздел «Метод» — проект намеренно
# на OAuth); --rm — контейнер харнеса не должен пережить вызов.
#
# --effort xhigh — тот же принцип фиксации, что и точный ID модели
# (CLAUDE.md, раздел «Не делать»): без явного флага харнесс полагался
# на дефолт CLI, который сам сдрейфовал между версиями Claude Code —
# 6 прогонов пилота от 2026-08-24 (до этого фикса) оказались под
# effort=high, а не xhigh, как задокументировано для более ранних
# прогонов на старом харнессе (проверено `grep` по `effort` в
# архивированных `transcript.jsonl`, не предположено). Переигран после
# фикса. Отдельно, известный и принятый (не устранимый без --bare,
# который ломает OAuth) артефакт харнеса: каждый вызов несёт небольшое
# сопутствующее использование claude-haiku-4-5 (~1500 токенов, ~$0.0015)
# — видно в `modelUsage` результата, не в основном `usage`. Не искажает
# сравнение между языками (одинаково на каждом вызове), но формально
# не «только claude-sonnet-5» — см. docs/EXPERIMENT-LOG.md.
#
# -v "$CLAUDE_HOME_DIR:/home/node/.claude" — свежая, пустая на старте,
# одноразовая для этого вызова директория (не хостовый ~/.claude
# целиком: тот содержит транскрипты ДРУГИХ языков/тикетов, монтировать
# его было бы тем же классом утечки, который устраняет вся эта
# Docker-обвязка). Без неё Claude Code пишет JSONL-транскрипт сессии
# внутрь контейнера, который затем удаляется вместе с `--rm` — сам факт
# отсутствия чтения/записи вне /workspace для этого больше не нужен
# (границу и так держит монтирование), но транскрипт нужен отдельно —
# для наблюдения зацикливаний/повторяющихся ошибок (CLAUDE.md, раздел
# «Лог») и чтобы peer review мог при желании перепроверить прогон
# построчно, не только по итоговому result.json.
CLAUDE_HOME_DIR="$(mktemp -d -t syncbox-claude-home)"
trap 'rm -rf "$CLAUDE_HOME_DIR"' EXIT
# CLAUDE_EXIT перехватывает код возврата явно ("|| CLAUDE_EXIT=$?"),
# а не даёт `set -e` оборвать скрипт здесь — иначе архивация ниже
# просто не выполняется на упавшем вызове. Найдено эмпирически
# (2026-08-24): Go, тикет 2, `claude -p` вернул ненулевой код из-за
# `429 session limit` — `${OUTPUT_PREFIX}.json` уже был записан
# редиректом (валидный JSON с `is_error: true`), но скрипт прерывался
# раньше строки архивации, и попытка терялась из архива целиком, не
# только частично, как в более раннем инциденте с ручной архивацией
# (см. ниже). Код возврата всё равно возвращается вызывающему в конце
# файла (`exit "$CLAUDE_EXIT"`) — кейсы провала не маскируются, только
# не блокируют архивацию.
CLAUDE_EXIT=0
# Свежий старт: убрать транскрипт прошлого прогона, чтобы не подхватить
# его, если текущий не допишет свой (entrypoint кладёт копию сюда).
rm -f "$PILOT_DIR/.harness-session-transcript.jsonl"

# Внешний wall-clock вокруг `docker run` — источник истины для полного
# времени попытки. Под DinD `duration_ms` из result.json недосчитывает
# (старт вложенного dockerd до запуска claude из него выпадает; на
# тикете 10 `duration_ms` < реального span'а транскрипта, а
# `duration_api_ms` его превышал — tool_ms_total уходил в минус, см.
# docs/incidents/2026-09-02-dind-timing-broken/). Меряем сами и отдаём
# analyze-timing-breakdown.py.
WALL_START_MS="$(python3 -c 'import time; print(int(time.time() * 1000))')"
docker run --rm -i \
  --privileged \
  -v "$PILOT_DIR:/workspace:rw" \
  -v /var/lib/docker \
  -v "$CLAUDE_HOME_DIR:/home/node/.claude" \
  --env-file "$ENV_FILE" \
  "$HARNESS_IMAGE" \
  claude -p \
    --model claude-sonnet-5 \
    --effort xhigh \
    --safe-mode \
    --dangerously-skip-permissions \
    --output-format json \
  <"$PROMPT_FILE" \
  >"${OUTPUT_PREFIX}.json" \
  2>"${OUTPUT_PREFIX}.stderr.log" \
  || CLAUDE_EXIT=$?
WALL_END_MS="$(python3 -c 'import time; print(int(time.time() * 1000))')"
CONTAINER_WALL_MS=$((WALL_END_MS - WALL_START_MS))

# Архивация промпта/спецификации/результата в docs/pilot-runs — без
# этого peer review не может проверить, что именно видел агент, не
# полагаясь на наши слова. Автоматически на каждый вызов, не вручную,
# и независимо от кода возврата claude -p (см. CLAUDE_EXIT выше) — не
# только на успех: два прогона тикета 2 на Go (2026-08-20) потеряли
# оригинальный result.json именно потому, что архивация была ручным
# шагом и не успела случиться до того, как следующая попытка
# перезаписала файл по тому же пути — см. docs/pilot-runs/README.md.
LANG_TAG="$(basename "$PILOT_DIR" | sed 's/^syncbox-//')"
# Имя файла-промпта: ticket-<N>-prompt.txt (обычный тикет бэклога) либо
# ticket-<N>-<slug>-prompt.txt для внеплановых фикс-тикетов
# (например ticket-12-fix-put500-prompt.txt -> бакет ticket-12-fix-put500).
# Лидирующая точка (dotfile в директории пилота) необязательна и срезается.
TICKET_TAG="$(basename "$PROMPT_FILE" | sed -E 's/^\.?ticket-([0-9]+(-[a-z0-9]+)*)-prompt\.txt$/\1/')"
SESSION_ID="$(python3 -c "import json; print(json.load(open('${OUTPUT_PREFIX}.json')).get('session_id',''))" 2>/dev/null || echo "unknown-session")"
ARCHIVE_DIR="$REPO_ROOT/docs/pilot-runs/$LANG_TAG/ticket-$TICKET_TAG/$SESSION_ID"
mkdir -p "$ARCHIVE_DIR"
cp "$PROMPT_FILE" "$ARCHIVE_DIR/prompt.txt"
cp "$PILOT_DIR/SYNCBOX-SPEC.md" "$ARCHIVE_DIR/SYNCBOX-SPEC.md"
cp "$PILOT_DIR/syncbox-openapi.yaml" "$ARCHIVE_DIR/syncbox-openapi.yaml"
cp "${OUTPUT_PREFIX}.json" "$ARCHIVE_DIR/result.json"

# Внешний тайминг попытки — рядом с result.json. container_wall_ms:
# полное время `docker run` (включая старт вложенного dockerd, загрузку
# предзапечённых образов, сам claude -p). analyze-timing-breakdown.py
# берёт его как базу вместо ненадёжного под DinD duration_ms.
printf '{"container_wall_ms": %s, "claude_exit": %s}\n' \
  "$CONTAINER_WALL_MS" "$CLAUDE_EXIT" > "$ARCHIVE_DIR/harness-timing.json"

# Полный JSONL-транскрипт сессии. Два источника, оба bind-mount'а:
#  1) $CLAUDE_HOME_DIR/projects/<slug>/<uuid>.jsonl — сюда claude пишет
#     транскрипт всю сессию. Читаем ПОСЛЕ возврата `docker run`: контейнер
#     уже снесён, virtiofs-writeback форсирован teardown'ом, данные на
#     хосте целиком.
#  2) $PILOT_DIR/.harness-session-transcript.jsonl — копию сюда кладёт
#     pilot-harness-entrypoint.sh ПЕРЕД teardown. Fallback на случай,
#     если (1) обрезан.
# Проверяем валидность каждого кандидата: непустой + первая непустая
# строка парсится как JSON. Иначе virtiofs на macOS может отдать
# NUL-заполненный файл правильного размера, если запись не сброшена до
# `--rm` teardown — так entrypoint-копия вышла 516 КБ нулей на
# переигровке тикета 10 (2026-09-03, docs/incidents/2026-09-03-dind-bash-missing/).
_valid_transcript() {
  [ -s "$1" ] || return 1
  head -c 4096 "$1" | tr -d '\0' | grep -q '[^[:space:]]' || return 1
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
for line in open(sys.argv[1], errors="replace"):
    line = line.strip("\x00 \t\r\n")
    if not line:
        continue
    json.loads(line)
    sys.exit(0)
sys.exit(1)
PY
}
TRANSCRIPT=""
_home_tr="$(find "$CLAUDE_HOME_DIR/projects" -name '*.jsonl' 2>/dev/null | head -1)"
_ws_tr="$PILOT_DIR/.harness-session-transcript.jsonl"
for _cand in "$_home_tr" "$_ws_tr"; do
  if [ -n "$_cand" ] && _valid_transcript "$_cand"; then
    TRANSCRIPT="$_cand"
    break
  fi
done
if [ -n "$TRANSCRIPT" ]; then
  cp "$TRANSCRIPT" "$ARCHIVE_DIR/transcript.jsonl"
  echo "run-pilot-ticket.sh: транскрипт из ${TRANSCRIPT#"$REPO_ROOT/"}" >&2
else
  echo "run-pilot-ticket.sh: ВАЛИДНЫЙ транскрипт не найден (проверены \$CLAUDE_HOME_DIR/projects и /workspace-копия) — архив без transcript.jsonl" >&2
fi
rm -f "$PILOT_DIR/.harness-session-transcript.jsonl"

# Код, который написал агент, — тоже архивируется, не только промпт и
# результат: нужен для независимого чтения peer review. Свои же
# служебные файлы (промпты прошлых тикетов, .git, если он вдруг
# появится) исключены — это не код агента. docs/pilot-runs/ этого
# мета-репозитория (как и весь остальной хост) внутри контейнера
# агента физически не примонтирован — агенту нечем прочитать архив
# соседних попыток и языков, даже если бы SYNCBOX-SPEC.md вдруг снова
# стал называть его по пути. SYNCBOX-SPEC.md тем не менее по-прежнему
# не должен называть или описывать этот архив — защита в глубину, а не
# полагание на единственный барьер.
#
# Установленные/сгенерированные директории (не код, который написал
# агент, а то, что поставили за него пакетный менеджер/компилятор)
# исключены отдельно — найдено эмпирически 2026-08-28: TypeScript
# ставит зависимости прямо в директорию пилота (`npm install` без
# `--prefix`), и без исключения `node_modules/` в архив тикета
# попадало под тысячу чужих файлов на каждый тикет (965 файлов/50МБ на
# один тикет TypeScript) — не то, что нужно peer review, и раздувает
# репозиторий метарепо на порядки против размера кода тикета. Список
# ниже — не только node_modules: те же классы артефактов у других
# языков (venv/сборочный вывод/кеш пакетного менеджера), даже если на
# сегодняшних семи языках пилота не все успели проявиться.
rsync -a --exclude='.ticket-*' --exclude='.git' \
  --exclude='.harness-session-transcript.jsonl' \
  --exclude='node_modules' --exclude='dist' --exclude='build' \
  --exclude='.venv' --exclude='venv' --exclude='__pycache__' \
  --exclude='vendor/bundle' --exclude='.bundle' \
  --exclude='target' --exclude='.bloop' --exclude='.metals' --exclude='.bsp' \
  --exclude='_build' --exclude='_opam' \
  "$PILOT_DIR/" "$ARCHIVE_DIR/code/"

# Разбивка времени на модель/инфраструктуру/работу — не гейт, не
# критерий "сошлось/сдалось", как и было с code quality: данные для
# последующего анализа. Требует result.json (для duration_api_ms) и
# transcript.jsonl (для построчной классификации Bash-команд) — если
# транскрипт не сохранился (см. блок выше), скрипт молча пропускается.
if [ -f "$ARCHIVE_DIR/transcript.jsonl" ]; then
  if python3 "$REPO_ROOT/scripts/analyze-timing-breakdown.py" "$ARCHIVE_DIR" >&2; then
    echo "Разбивка времени: $ARCHIVE_DIR/timing-breakdown.json" >&2
  else
    echo "run-pilot-ticket.sh: analyze-timing-breakdown.py упал — не критично, не гейт" >&2
  fi
else
  echo "run-pilot-ticket.sh: разбивка времени пропущена — нет transcript.jsonl" >&2
fi

echo "Архив попытки: $ARCHIVE_DIR" >&2

# Код возврата claude -p (см. CLAUDE_EXIT выше), не 0 — архивация
# упавшего вызова не должна маскировать сам факт провала от вызывающей
# стороны (Makefile, дальнейшие шаги пилота).
exit "$CLAUDE_EXIT"
