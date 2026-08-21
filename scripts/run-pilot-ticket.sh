#!/usr/bin/env bash
# Запускает один тикет через Claude Code headless против директории
# пилотного проекта конкретного языка — с файловой песочницей,
# физически ограничивающей чтение пределами этой директории.
#
# Зачем: первый же реальный прогон (тикет 1, Python, 2026-08-19) показал
# 100%-воспроизводимую утечку — агент прочитал `acceptance/reference-impl`
# этого мета-репозитория и скопировал оттуда решения. `--safe-mode`
# отключает CLAUDE.md/хуки/скиллы/плагины мета-репозитория, но не
# ограничивает файловую систему — этого недостаточно самого по себе.
# Разбор: docs/incidents/2026-08-19-python-ticket1-contamination/.
#
# sandbox.filesystem.denyRead/allowRead — часть полей sandbox читается
# только из user/managed/CLI (--settings) настроек, из project-level
# .claude/settings.json — нет, поэтому передаём файлом через --settings,
# а не кладём в пилотный проект.
#
# Файловая песочница не покрывает общий Docker-демон хоста: агенту
# нужен доступ к docker-сокету для сборки/тестирования своего же
# контейнера (см. network.allowAllUnixSockets ниже), а через него
# `docker images`/`docker ps` показывают образы и контейнеры от
# эталонной реализации и от прошлых пилотных прогонов — второй,
# более мягкий канал утечки (агент не читает чужой код, но видит,
# что чужие прогоны существуют, и это самого по себе достаточно,
# чтобы повлиять на его решения — см. раздел «Docker daemon» в
# разборе инцидента). Поэтому перед каждым запуском чистим все
# ресурсы с префиксом `syncbox` — не только чужие: если это
# `--resume` в рамках одного тикета, свои же образа тоже будут
# пересобраны, это принятая цена фикса, а не побочный баг.
#
# Использование:
#   scripts/run-pilot-ticket.sh <pilot-dir> <prompt-file> <output-prefix>
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
PARENT_DIR="$(dirname "$PILOT_DIR")"
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

SETTINGS_FILE="$(mktemp -t syncbox-sandbox-settings)"
trap 'rm -f "$SETTINGS_FILE"' EXIT

python3 - "$PARENT_DIR" "$PILOT_DIR" >"$SETTINGS_FILE" <<'PY'
import json
import os
import sys

parent, pilot = sys.argv[1], sys.argv[2]
json.dump(
    {
        "sandbox": {
            "enabled": True,
            # молчаливый откат к несандбоксированному запуску (дефолт
            # Claude Code при недоступности песочницы) для этого скрипта
            # неприемлем — тогда фикс контаминации незаметно перестаёт
            # действовать; лучше упасть явно.
            "failIfUnavailable": True,
            # без этого агент может сам, по собственному решению, снять
            # песочницу на конкретную Bash-команду через параметр
            # dangerouslyDisableSandbox инструмента Bash — под
            # --dangerously-skip-permissions это не требует чьего-либо
            # подтверждения. Найдено на живом прогоне (Go, тикет 1,
            # 2026-08-20): агент 18 раз снимал песочницу ради `docker
            # buildx`, пишущего в ~/.docker/buildx/activity вне
            # allowRead — по счастью, ни разу не прочитал ничего за
            # пределами своей директории, но сама возможность обхода
            # ровно то, что denyRead/allowRead ниже должны исключать.
            "allowUnsandboxedCommands": False,
            "filesystem": {
                "denyRead": [parent],
                "allowRead": [pilot],
                # docker buildx пишет служебное состояние (не креды —
                # те в ~/.docker/config.json, сюда не входит) в
                # ~/.docker/buildx/{activity,current,instances,...} —
                # без этого сборка образа падает "operation not
                # permitted" на каждом тикете, где нужен пересобранный
                # образ, и агент вынужден либо отключать песочницу
                # целиком (закрыто выше), либо пропускать Docker E2E.
                "allowWrite": [os.path.expanduser("~/.docker/buildx")],
            },
            "network": {
                # docker-сокет и локальные HTTP-вызовы (curl к серверу
                # тикета на 127.0.0.1) не должны блокироваться.
                "allowAllUnixSockets": True,
                "allowLocalBinding": True,
                # Предположение "исходящий трафик в интернет идёт из
                # демона Docker, не из сендбоксируемого процесса" не
                # подтвердилось: на живом прогоне (Go, тикет 2,
                # 2026-08-20) клиентский процесс `docker build`
                # (buildx) сам делает HTTPS-запрос за OAuth-токеном к
                # auth.docker.io и падает с ошибкой проверки
                # TLS-сертификата — сборка образа, ещё не закешированного
                # локально, невозможна без явного allowedDomains.
                # Подтверждено диагностическим прогоном: с этим списком
                # `docker pull alpine:3.20` (не закешированный) успешен.
                # Не решает вопрос для будущих языков в общем виде —
                # свои реестры пакетов (PyPI, RubyGems, npm, opam,
                # Maven) при необходимости добавлять сюда по факту
                # обнаружения тем же способом, не заранее списком.
                "allowedDomains": [
                    "auth.docker.io",
                    "registry-1.docker.io",
                    "production.cloudflare.docker.com",
                    "*.docker.io",
                    "*.cloudflare.docker.com",
                ],
            },
        }
    },
    sys.stdout,
    ensure_ascii=False,
    indent=2,
)
PY

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

cd "$PILOT_DIR"
# --permission-mode dontAsk молча (и, по наблюдению, непредсказуемо)
# отклоняет Edit/Write без TTY — не покрытые allow-правилом вызовы
# инструментов при dontAsk в headless-режиме отклоняются по умолчанию,
# а не разрешаются. Один прогон тикета 2 (2026-08-20) вышел success
# кодом 0, не внеся ни одной правки — агент прямым текстом сообщил,
# что Edit/Write отклонены системой разрешений. --dangerously-skip-permissions
# снимает проверки разрешений целиком — решение осознанно принято поверх
# уже существующей границы безопасности (--safe-mode + файловая
# песочница sandbox.filesystem, см. выше), не вместо неё.
claude -p \
  --model claude-sonnet-5 \
  --safe-mode \
  --settings "$SETTINGS_FILE" \
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
# код агента. denyRead на родителя пилотной директории (см. sandbox
# выше) покрывает и docs/pilot-runs/ этого мета-репозитория тем же
# образом, что и acceptance/reference-impl — SYNCBOX-SPEC.md никогда
# не должен называть или описывать этот архив по пути, иначе получим
# повтор исходного инцидента контаминации с новым именем директории.
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
