# Контейнер для самого харнеса (claude -p), не для кода тикета —
# отдельное, более сильное требование поверх «код тикета — в Docker»
# из docs/SYNCBOX-SPEC.md. Причина: Claude Code внутренне не умеет
# ограничивать по пути ни Read (governed только permissions, которые
# --dangerously-skip-permissions полностью отключает), ни тем более
# Write (вообще не поддерживает path-scoping ни в каком режиме —
# подтверждено трижды эмпирически и документацией permissions.md) —
# см. разбор в docs/incidents/2026-08-21-write-tool-sandbox-escape/.
# Внешняя, ядром обеспечиваемая изоляция контейнера — единственный
# проверенный барьер, который агент не может обойти изнутри.
#
# Docker-IN-Docker, не Docker-out-of-Docker (переход 2026-09-01).
# Раньше внутрь пробрасывался хостовый /var/run/docker.sock, и `docker
# compose` агента шёл в тот же демон, что и весь хост. Прогон тикета 9
# (Ruby) показал: через это агент может получить bind-mount ЛЮБОГО
# хостового пути под каталогом file-sharing Docker Desktop — `run-client
# status /tmp` примонтировал хостовый /private/tmp в контейнер клиента и
# обошёл его целиком (чужие сессии Claude Code, скрэтч этого же
# эксперимента). Демон резолвит путь bind-mount против СВОЕГО вида хоста,
# и ремап пути внутри харнеса на это не влияет — проверено. Разбор:
# docs/incidents/2026-09-01-dood-host-fs-reachable/.
#
# С DinD внутри поднимается собственный dockerd (нужен --privileged на
# `docker run` харнеса). Его файловая система — оверлей самого контейнера
# харнеса; хостовых /private/tmp и /Users в ней не существует, поэтому
# `docker compose` агента физически не может их примонтировать. Бонусом
# уходит и прежняя утечка через `docker inspect` своего же контейнера
# (host-side путь bind-mount'а с именем мета-репозитория — см.
# docs/incidents/2026-08-26-docker-inspect-hostpath-leak/): внутренний
# демон про контейнер харнеса ничего не знает. `/var/lib/docker` —
# анонимный том (VOLUME из базового образа), `--rm` сносит его вместе с
# контейнером: демон каждого прогона пуст, чистить чужие/прошлые
# `syncbox*`-образы больше не нужно и негде.
#
# Цена, принятая осознанно: (1) --privileged на том же контейнере, где
# уже claude -p --dangerously-skip-permissions — это не расширение
# периметра, барьер по-прежнему один (namespace-изоляция самого
# контейнера от хоста), просто теперь замкнутый; (2) внутренний демон
# стартует без кеша слоёв. Базовые образы (python:3.12-slim,
# node:22-alpine, ruby:3.3-slim, alpine) предзапечены в этот образ
# харнеса как /base-images.tar (scripts/build-base-images-tar.sh) и
# `docker load`-ятся вложенным демоном на старте — иначе `docker compose
# build` кода тикета тянул бы базу с registry каждый прогон (~1-2 мин),
# и это время попадало бы в измеряемый duration по-разному для разных
# языков (сломало метрику на тикете 10 —
# docs/incidents/2026-09-02-dind-timing-broken/). Сам pull базы —
# один раз, при сборке этого образа, в duration прогонов не входит.
#
# Версия Claude Code закреплена (не @latest) — тот же принцип, что и
# точный ID модели: дрейф версии харнеса не должен подмешиваться к
# измеряемому эффекту языка без явного, документированного решения
# поменять её. Базовый docker:27-dind — Alpine; nodejs/npm ставятся
# apk из репозитория Alpine (musl-нативные, без glibc/musl-конфликта,
# который был бы с бинарником docker из Debian-образа), su-exec —
# сбросить root после старта dockerd (claude -p не работает под root).
FROM docker:27-dind

RUN apk add --no-cache nodejs npm su-exec curl ca-certificates git

RUN npm install -g @anthropic-ai/claude-code@2.1.238

# dockerd обязан стартовать под root; полезная нагрузка (claude -p) — нет.
RUN adduser -D -u 1000 node

# Внутренний dockerd слушает только unix-сокет, без TLS и без TCP.
ENV DOCKER_TLS_CERTDIR=""

# Предзапечённые базовые образы языковых стендов — грузятся вложенным
# демоном в pilot-harness-entrypoint.sh. Генерится scripts/build-base-images-tar.sh
# (гитигнорится). Если файла нет — сборка не падает, но прогоны будут
# тянуть базу с registry (медленнее, метрика времени зашумлена).
COPY base-images.ta[r] /base-images.tar

COPY pilot-harness-entrypoint.sh /usr/local/bin/pilot-harness-entrypoint.sh
RUN chmod +x /usr/local/bin/pilot-harness-entrypoint.sh

# Агент стартует в директории пилота, как и на прежнем (DooD) харнессе.
# Пропало при переходе на docker:27-dind (в его образе своего WORKDIR
# нет), из-за чего на тикетах 9-shakedown и 10 claude запускался из `/`
# и сам доходил до /workspace — восстановлено.
WORKDIR /workspace

# ENTRYPOINT базового образа (dockerd-entrypoint.sh) переопределяется:
# наш скрипт поднимает dockerd в фоне через него же, ждёт сокет,
# сбрасывает привилегии и запускает переданный CMD (claude -p ...).
ENTRYPOINT ["/usr/local/bin/pilot-harness-entrypoint.sh"]
