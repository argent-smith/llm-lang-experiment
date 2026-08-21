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
# Использование:
#   scripts/run-pilot-ticket.sh <pilot-dir> <prompt-file> <output-prefix>
#
# Предпосылка: scripts/pilot-harness.env с CLAUDE_CODE_OAUTH_TOKEN (см.
# scripts/pilot-harness.env.example) и собранный образ
# pilot-harness:latest (пересобирается автоматически, если отсутствует
# или Dockerfile новее уже собранного).
#
# Пишет:
#   <output-prefix>.json        — результат --output-format json
#   <output-prefix>.stderr.log  — stderr прогона
#   docs/pilot-runs/<язык>/ticket-<N>/<session_id>/ — архивная копия
#     промпта, спецификации/схемы и результата (для peer review, см.
#     docs/pilot-runs/README.md); <язык> и <N> определяются по именам
#     <pilot-dir> и <prompt-file>.

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
# Пересобрать, если образа ещё нет или Dockerfile правился после
# последней сборки — та же логика, что ленивая пересборка у
# run-server/run-client (docs/RUNBOOK.md), не пересобираем на каждый
# вызов вслепую.
NEED_BUILD=1
if IMAGE_CREATED="$(docker image inspect -f '{{.Created}}' "$HARNESS_IMAGE" 2>/dev/null)"; then
  IMAGE_EPOCH="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${IMAGE_CREATED%%.*}" +%s 2>/dev/null || date -d "$IMAGE_CREATED" +%s)"
  DOCKERFILE_EPOCH="$(stat -f %m "$HARNESS_DOCKERFILE" 2>/dev/null || stat -c %Y "$HARNESS_DOCKERFILE")"
  [ "$IMAGE_EPOCH" -ge "$DOCKERFILE_EPOCH" ] && NEED_BUILD=0
fi
if [ "$NEED_BUILD" -eq 1 ]; then
  # --provenance=false/--sbom=false: без них Docker Desktop (containerd
  # image store, включён по умолчанию) экспортирует attestation-манифест
  # вместе с образом и не может протегировать результат под обычным
  # именем — `docker build` рапортует "naming to ... done", но `docker
  # images`/`docker run` затем не находят образ вообще (воспроизведено
  # эмпирически на этом хосте). Не специфика конкретно этого образа —
  # общий эффект containerd-стора с buildx, для локальных однократных
  # сборок provenance/SBOM не несут пользы.
  docker build --provenance=false --sbom=false -t "$HARNESS_IMAGE" -f "$HARNESS_DOCKERFILE" "$REPO_ROOT/scripts" >&2
fi

# Путь к docker-сокету через `docker context inspect`, не хардкод
# /var/run/docker.sock — на Docker Desktop/macOS реальный сокет лежит
# в ~/.docker/run/docker.sock, /var/run/docker.sock там просто симлинк
# на хосте (внутри контейнера его нет). На Linux-хосте (в т.ч. CI)
# тот же вызов вернёт unix:///var/run/docker.sock — воспроизводимо без
# правки скрипта под ОС.
DOCKER_SOCK="$(docker context inspect -f '{{.Endpoints.docker.Host}}' | sed 's#^unix://##')"

# Чистка общего Docker-демона хоста от всего, что несёт префикс
# "syncbox" (образы, контейнеры, сети) — до эталонной реализации и
# прошлых пилотных прогонов включительно. `|| true` на каждом шаге:
# пустой список — нормальный случай, не ошибка.
docker ps -a --filter "name=syncbox" --format '{{.ID}}' | xargs -r docker rm -f >/dev/null 2>&1 || true
docker images --filter "reference=syncbox*" --format '{{.ID}}' | xargs -r docker rmi -f >/dev/null 2>&1 || true
docker network ls --filter "name=syncbox" --format '{{.ID}}' | xargs -r docker network rm >/dev/null 2>&1 || true

# Проверка, что чистка реально сработала — тем же духом, что
# failIfUnavailable для файловой песочницы: молчаливый недобитый
# остаток (`|| true` выше глотает и настоящие ошибки docker, не
# только "пустой список") оставлял бы более мягкий канал утечки не
# закрытым, а просто незамеченным.
leftover_containers="$(docker ps -a --filter "name=syncbox" --format '{{.Names}}')"
leftover_images="$(docker images --filter "reference=syncbox*" --format '{{.Repository}}:{{.Tag}}')"
leftover_networks="$(docker network ls --filter "name=syncbox" --format '{{.Name}}')"
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
docker run --rm -i \
  -v "$PILOT_DIR:/workspace:rw" \
  -v "$DOCKER_SOCK:/var/run/docker.sock" \
  --env-file "$ENV_FILE" \
  "$HARNESS_IMAGE" \
  claude -p \
    --model claude-sonnet-5 \
    --safe-mode \
    --dangerously-skip-permissions \
    --output-format json \
  <"$PROMPT_FILE" \
  >"${OUTPUT_PREFIX}.json" \
  2>"${OUTPUT_PREFIX}.stderr.log"

# Архивация промпта/спецификации/результата в docs/pilot-runs — без
# этого peer review не может проверить, что именно видел агент, не
# полагаясь на наши слова. Автоматически на каждый вызов, не вручную:
# два прогона тикета 2 на Go (2026-08-20) потеряли оригинальный
# result.json именно потому, что архивация была ручным шагом и не
# успела случиться до того, как следующая попытка перезаписала файл
# по тому же пути — см. docs/pilot-runs/README.md.
LANG_TAG="$(basename "$PILOT_DIR" | sed 's/^syncbox-//')"
TICKET_TAG="$(basename "$PROMPT_FILE" | sed -E 's/^\.?ticket-([0-9]+)-prompt\.txt$/\1/')"
SESSION_ID="$(python3 -c "import json; print(json.load(open('${OUTPUT_PREFIX}.json')).get('session_id',''))" 2>/dev/null || echo "unknown-session")"
ARCHIVE_DIR="$REPO_ROOT/docs/pilot-runs/$LANG_TAG/ticket-$TICKET_TAG/$SESSION_ID"
mkdir -p "$ARCHIVE_DIR"
cp "$PROMPT_FILE" "$ARCHIVE_DIR/prompt.txt"
cp "$PILOT_DIR/SYNCBOX-SPEC.md" "$ARCHIVE_DIR/SYNCBOX-SPEC.md"
cp "$PILOT_DIR/syncbox-openapi.yaml" "$ARCHIVE_DIR/syncbox-openapi.yaml"
cp "${OUTPUT_PREFIX}.json" "$ARCHIVE_DIR/result.json"

# Код, который написал агент, — тоже архивируется, не только промпт и
# результат: без него нечего проверять code quality в CI, и нечего
# независимо прочитать peer review. Свои же служебные файлы (промпты
# прошлых тикетов, .git, если он вдруг появится) исключены — это не
# код агента. docs/pilot-runs/ этого мета-репозитория (как и весь
# остальной хост) внутри контейнера агента физически не примонтирован —
# агенту нечем прочитать архив соседних попыток и языков, даже если бы
# SYNCBOX-SPEC.md вдруг снова стал называть его по пути. SYNCBOX-SPEC.md
# тем не менее по-прежнему не должен называть или описывать этот архив —
# защита в глубину, а не полагание на единственный барьер.
rsync -a --exclude='.ticket-*' --exclude='.git' "$PILOT_DIR/" "$ARCHIVE_DIR/code/"

# Code quality — автоматически на каждый прогон (то, что раньше
# называлось "CI" в CLAUDE.md только на словах): не гейтит цикл ревью,
# только данные. Молча пропускается для языков, для которых
# run-code-quality.sh ещё не реализован (Scala/OCaml) — не ошибка.
if "$REPO_ROOT/scripts/run-code-quality.sh" "$LANG_TAG" "$PILOT_DIR" "$ARCHIVE_DIR/quality" 2>"$ARCHIVE_DIR/quality.stderr.log"; then
  echo "Code quality: $ARCHIVE_DIR/quality-quality.json" >&2
else
  echo "Code quality для '$LANG_TAG' не прогнан (см. $ARCHIVE_DIR/quality.stderr.log) — не критично, не гейт" >&2
fi

echo "Архив попытки: $ARCHIVE_DIR" >&2
