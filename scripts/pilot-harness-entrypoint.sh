#!/bin/sh
# ENTRYPOINT образа харнеса (Docker-in-Docker). Поднимает вложенный
# dockerd, подгружает предзапечённые базовые образы, сбрасывает root и
# запускает переданный CMD (claude -p ...) от непривилегированного
# пользователя. После выхода claude — копирует транскрипт сессии на
# надёжный bind-mount и досбрасывает буферы ФС до teardown контейнера.
#
# dockerd обязан стартовать под root. claude -p с
# --dangerously-skip-permissions под root работать отказывается (само по
# себе разумное ограничение) — отсюда двухшаговый запуск: root поднимает
# демон, su-exec роняет привилегии для полезной нагрузки.
#
# ВАЖНО: не `exec` — управление должно вернуться в этот скрипт после
# claude. Иначе (claude как PID 1 + `--rm`) контейнер убивается мгновенно
# по выходе claude, и последние, ещё не сброшенные на bind-mount записи
# транскрипта теряются: под DinD virtiofs не успевает синхронизировать
# $CLAUDE_HOME_DIR. Наблюдалось на тикете 10 — архивный transcript.jsonl
# охватывал ~12% времени прогона, docker-команды агента в нём
# отсутствовали, и scripts/analyze-timing-breakdown.py не мог посчитать
# инфра/работу (см. docs/incidents/2026-09-02-dind-timing-broken/).
set -eu

# dockerd-entrypoint.sh из базового docker:27-dind делает
# iptables/cgroups/выбор storage-драйвера и стартует dockerd только если
# первый аргумент — dockerd (иначе уходит в клиентский режим и демон не
# поднимает). Даём аргумент явно, в фоне, лог — в /tmp (внутренний,
# оверлей контейнера харнеса; не хостовый).
dockerd-entrypoint.sh dockerd --host=unix:///var/run/docker.sock \
  >/tmp/dockerd.log 2>&1 &

# Ждём готовности демона (холодный старт + возможная инициализация
# storage — обычно 2-8 с).
i=0
while ! docker version >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "pilot-harness-entrypoint: вложенный dockerd не поднялся за 60 с" >&2
    cat /tmp/dockerd.log >&2 || true
    exit 1
  fi
  sleep 1
done

# Предзапечённые базовые образы (python:3.12-slim, node:22-alpine,
# ruby:3.3-slim, alpine — см. scripts/build-base-images-tar.sh). Внутренний
# демон DinD стартует с пустым /var/lib/docker (анонимный том, --rm его
# сносит — так закрыт канал утечки через `docker images`), поэтому без
# предзагрузки `docker compose build` кода тикета каждый раз тянет базу с
# registry — ~1-2 мин, попадающие в измеряемое время прогона по-разному
# для разных языков. `docker load` из локального tar — ~5-15 с и
# детерминирован; сам pull базы выполнен один раз при сборке образа
# харнеса и в duration прогонов не входит.
if [ -f /base-images.tar ]; then
  docker load -i /base-images.tar >/tmp/base-load.log 2>&1 \
    || echo "pilot-harness-entrypoint: docker load /base-images.tar не удался (не критично)" >&2
fi

# Сокет внутреннего демона — root:root. Контейнер эфемерный (--rm), не
# слушает сеть, живёт один вызов: проще открыть сокет, чем заводить
# группы. Полезная нагрузка (claude -p и её docker compose) обращается
# к нему уже от пользователя node.
chmod 666 /var/run/docker.sock

# su-exec не наследует HOME пользователя — claude ищет ~/.claude по
# $HOME, туда же примонтирована одноразовая директория транскрипта.
export HOME=/home/node

# Пост-обработка (копия транскрипта на надёжный bind-mount + sync до
# teardown) — через EXIT-trap, НЕ через бэкграунд `&`: асинхронная
# команда в POSIX sh получает stdin из /dev/null, а `claude -p` читает
# промпт со stdin (`run-pilot-ticket.sh` подаёт его через `<файл`).
# Trap отрабатывает и на упавшем claude под `set -e` ($? в EXIT-trap —
# это код, вызвавший выход).
# shellcheck disable=SC2329,SC2317  # вызывается косвенно через trap EXIT
_finish() {
  rc=$?
  # Транскрипт сессии claude — в $HOME/.claude/projects/<slug>/<uuid>.jsonl.
  # $CLAUDE_HOME_DIR пуст на старте (mktemp -d в run-pilot-ticket.sh),
  # сессия одна — .jsonl ожидается ровно один (несколько — берём
  # последний по порядку глоба).
  rm -f /workspace/.harness-session-transcript.jsonl
  transcript_src=""
  for f in /home/node/.claude/projects/*/*.jsonl; do
    [ -f "$f" ] && transcript_src="$f"
  done
  if [ -n "$transcript_src" ]; then
    cp "$transcript_src" /workspace/.harness-session-transcript.jsonl 2>/dev/null \
      || echo "pilot-harness-entrypoint: не удалось скопировать транскрипт в /workspace" >&2
  else
    echo "pilot-harness-entrypoint: транскрипт сессии не найден в ~/.claude/projects" >&2
  fi
  sync
  exit "$rc"
}
trap _finish EXIT

su-exec node "$@"
