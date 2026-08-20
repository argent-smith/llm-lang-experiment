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
            "filesystem": {
                "denyRead": [parent],
                "allowRead": [pilot],
            },
            "network": {
                # docker-сокет и локальные HTTP-вызовы (curl к серверу
                # тикета на 127.0.0.1) не должны блокироваться —
                # исходящий трафик в интернет (pip/docker pull) в любом
                # случае идёт из демона Docker, не из сендбоксируемого
                # процесса, поэтому allowedDomains/strictAllowlist здесь
                # не трогаем.
                "allowAllUnixSockets": True,
                "allowLocalBinding": True,
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
