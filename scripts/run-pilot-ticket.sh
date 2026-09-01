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
# Файловая изоляция контейнера не покрывает общий Docker-демон хоста:
# агенту нужен доступ к docker-сокету для сборки/тестирования своего же
# контейнера (Docker-out-of-Docker — /var/run/docker.sock пробрасывается
# внутрь), а через него `docker images`/`docker ps` показывают образы и
# контейнеры от эталонной реализации и от прошлых пилотных прогонов —
# второй, более мягкий канал утечки (агент не читает чужой код, но
# видит, что чужие прогоны существуют, и это само по себе достаточно,
# чтобы повлиять на его решения). Поэтому перед каждым запуском чистим
# все ресурсы с префиксом `syncbox` — не только чужие: если это
# `--resume` в рамках одного тикета, свои же образы тоже будут
# пересобраны, это принятая цена фикса, а не побочный баг.
#
# Тот же демон-канал раскрывает и host-side пути bind-mount'ов:
# `docker inspect <контейнер> --format '{{json .Mounts}}'` (в т.ч. для
# СВОЕГО ЖЕ контейнера харнеса, который агент видит через `docker ps`)
# отдаёт реальный путь на хосте — включая имя мета-репозитория
# `llm-lang-experiment`, ровно то, что вся эта Docker-обвязка должна
# скрывать. Обнаружено эмпирически на первом прогоне TypeScript (тикет
# 1, 2026-08-26) — см. docs/incidents/2026-08-26-docker-inspect-hostpath-leak/.
# Файловый барьер это не пробивает (путь физически не существует внутри
# контейнера, попытка использовать его падает), но имя/путь агент
# узнаёт. Полностью закрыть без потери docker.sock нельзя — демон не
# различает «свой» и «чужой» контейнер и не фильтрует поля ответа;
# принято как тот же класс риска, что и `docker images`/`docker ps`
# выше, не устранено.
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

# Без префикса "syncbox" намеренно: очистка Docker-демона ниже сносит
# все образы с ссылкой "syncbox*" (код тикетов, эталонная реализация) —
# образ харнеса, названный так же, попадал бы под собственную чистку и
# исчезал сразу после сборки (воспроизведено эмпирически на этом хосте).
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

# Путь к docker-сокету через `docker context inspect`, не хардкод
# /var/run/docker.sock — на Docker Desktop/macOS реальный сокет лежит
# в ~/.docker/run/docker.sock, /var/run/docker.sock там просто симлинк
# на хосте (внутри контейнера его нет). На Linux-хосте (в т.ч. CI)
# тот же вызов вернёт unix:///var/run/docker.sock — воспроизводимо без
# правки скрипта под ОС.
DOCKER_SOCK="$(docker context inspect -f '{{.Endpoints.docker.Host}}' | sed 's#^unix://##')"

# Чистка общего Docker-демона хоста от всего, что несёт префикс
# "syncbox" (образы, контейнеры, сети) — до эталонной реализации и
# прошлых пилотных прогонов включительно. Плюс отдельно —
# "^workspace-"/"^workspace_": рабочая директория внутри контейнера
# харнеса всегда /workspace (см. WORKDIR в pilot-harness.Dockerfile),
# поэтому `docker compose` без явного `name:` в файле проекта
# детерминированно берёт "workspace" как имя проекта — контейнеры вида
# `workspace-<сервис>-run-<hash>` не совпадают с фильтром "syncbox" и
# переживают вызов, если сессия оборвалась до штатного `compose down`
# (найдено эмпирически: сервер, поднятый `run-server` внутри тикета,
# пережил обрыв по рейт-лимиту 429 и следующие два прогона, пока не
# найден при ручной проверке). `^` — привязка к началу имени, чтобы не
# зацепить случайный контейнер стороннего проекта разработчика с
# "workspace" где-то в середине имени. `|| true` на каждом шаге:
# пустой список — нормальный случай, не ошибка.
docker ps -a --filter "name=syncbox" --filter "name=^workspace-" --format '{{.ID}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
docker images --filter "reference=syncbox*" --format '{{.ID}}' | xargs -r docker rmi -f >/dev/null 2>&1 || true
docker network ls --filter "name=syncbox" --filter "name=^workspace_" --format '{{.ID}}' | xargs -r docker network rm >/dev/null 2>&1 || true

# Проверка, что чистка реально сработала — тем же духом, что
# failIfUnavailable для файловой песочницы: молчаливый недобитый
# остаток (`|| true` выше глотает и настоящие ошибки docker, не
# только "пустой список") оставлял бы более мягкий канал утечки не
# закрытым, а просто незамеченным.
leftover_containers="$(docker ps -a --filter "name=syncbox" --filter "name=^workspace-" --format '{{.Names}}')"
leftover_images="$(docker images --filter "reference=syncbox*" --format '{{.Repository}}:{{.Tag}}')"
leftover_networks="$(docker network ls --filter "name=syncbox" --filter "name=^workspace_" --format '{{.Name}}')"
if [ -n "$leftover_containers$leftover_images$leftover_networks" ]; then
  echo "run-pilot-ticket.sh: очистка Docker-демона от ресурсов 'syncbox' не удалась, остались:" >&2
  [ -n "$leftover_containers" ] && echo "  контейнеры: $leftover_containers" >&2
  [ -n "$leftover_images" ] && echo "  образы: $leftover_images" >&2
  [ -n "$leftover_networks" ] && echo "  сети: $leftover_networks" >&2
  exit 1
fi

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
# /workspace и docker-сокета.
#
# -v "$PILOT_DIR:/workspace:rw" — единственная примонтированная
# директория с кодом; -v "$DOCKER_SOCK:/var/run/docker.sock" —
# Docker-out-of-Docker для сборки/тестирования кода тикета в соседнем
# контейнере (см. «Docker-изоляция» в docs/SYNCBOX-SPEC.md); --env-file
# передаёт CLAUDE_CODE_OAUTH_TOKEN, не ANTHROPIC_API_KEY (см. CLAUDE.md,
# раздел «Метод» — проект намеренно на OAuth); --rm — контейнер харнеса
# не должен пережить вызов, в отличие от контейнера кода тикета внутри
# него, который отдельно чистится блоком выше на СЛЕДУЮЩЕМ вызове.
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
docker run --rm -i \
  -v "$PILOT_DIR:/workspace:rw" \
  -v "$DOCKER_SOCK:/var/run/docker.sock" \
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

# Полный JSONL-транскрипт сессии — из одноразового $CLAUDE_HOME_DIR
# (см. docker run выше), не из хостового ~/.claude: там его нет и не
# будет для контейнеризованных вызовов. Копируем до срабатывания trap,
# который снесёт $CLAUDE_HOME_DIR при выходе. Один файл ожидается
# (cwd внутри контейнера всегда /workspace, кодируется в одно и то же
# имя поддиректории projects/) — если файлов несколько или их нет,
# берём что есть/пропускаем без падения всего скрипта, транскрипт не
# входит в критерии сошлось/сдалось.
TRANSCRIPT="$(find "$CLAUDE_HOME_DIR/projects" -name '*.jsonl' 2>/dev/null | head -1)"
if [ -n "$TRANSCRIPT" ]; then
  cp "$TRANSCRIPT" "$ARCHIVE_DIR/transcript.jsonl"
else
  echo "run-pilot-ticket.sh: транскрипт сессии не найден в $CLAUDE_HOME_DIR/projects — архив без transcript.jsonl" >&2
fi

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
