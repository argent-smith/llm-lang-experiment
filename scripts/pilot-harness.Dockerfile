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
# docker CLI + compose-плагин скопированы из официального docker:27-cli
# образа (Docker-out-of-Docker: /var/run/docker.sock монтируется с
# хоста при запуске, команды агента идут в тот же демон, что и
# остальной пилот, контейнеры создаются как соседи, не вложенно) — не
# apt-get install docker.io, тот тянет свою версию и не даёт compose.
#
# Версия Claude Code закреплена (не @latest) — тот же принцип, что и
# точный ID модели: дрейф версии харнеса не должен подмешиваться к
# измеряемому эффекту языка без явного, документированного решения
# поменять её.

FROM node:22-slim

COPY --from=docker:27-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:27-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@2.1.238

# --dangerously-skip-permissions отказывается работать под root/sudo
# (само по себе разумное ограничение) — базовый node-образ уже даёт
# непривилегированного пользователя node (uid 1000), используем его.
# docker.sock, примонтированный с хоста (Docker Desktop, macOS),
# внутри контейнера виден как root:root, rw-rw---- — не так, как
# показывает `ls` на самом хосте (там владелец paul:staff): Docker
# Desktop переинтерпретирует владение файлом через VM-прослойку
# (gRPC-FUSE/VirtioFS). Значение имеет только то, что видно ИЗНУТРИ
# контейнера — добавляем node в группу root (gid 0), не в group хоста.
RUN usermod -aG root node
USER node
WORKDIR /workspace
