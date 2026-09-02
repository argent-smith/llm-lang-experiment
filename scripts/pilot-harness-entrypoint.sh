#!/bin/sh
# ENTRYPOINT образа харнеса (Docker-in-Docker). Поднимает вложенный
# dockerd, дожидается его готовности, сбрасывает root и запускает
# переданный CMD (claude -p ...) от непривилегированного пользователя.
#
# dockerd обязан стартовать под root. claude -p с
# --dangerously-skip-permissions под root работать отказывается (само по
# себе разумное ограничение) — отсюда двухшаговый запуск: root поднимает
# демон, su-exec роняет привилегии для полезной нагрузки.
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

# Сокет внутреннего демона — root:root. Контейнер эфемерный (--rm), не
# слушает сеть, живёт один вызов: проще открыть сокет, чем заводить
# группы. Полезная нагрузка (claude -p и её docker compose) обращается
# к нему уже от пользователя node.
chmod 666 /var/run/docker.sock

# su-exec не наследует HOME пользователя — claude ищет ~/.claude по
# $HOME, туда же примонтирована одноразовая директория транскрипта.
export HOME=/home/node

exec su-exec node "$@"
