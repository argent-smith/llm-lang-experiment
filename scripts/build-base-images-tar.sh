#!/usr/bin/env bash
# Тянет базовые образы языковых стендов и сохраняет в scripts/base-images.tar,
# который COPY-ится в образ харнеса (scripts/pilot-harness.Dockerfile) и
# `docker load`-ится вложенным dockerd на старте (pilot-harness-entrypoint.sh).
#
# Зачем: внутренний демон DinD стартует с пустым /var/lib/docker (анонимный
# том, --rm его сносит — так закрыт канал утечки через `docker images`).
# Без предзагрузки `docker compose build` кода тикета каждый прогон тянет
# базу с registry (~1-2 мин), и это время попадает в измеряемый duration
# по-разному для разных языков, искажая метрику «время (API/инфра/работа)».
# `docker load` из локального tar детерминирован (~5-15 с) и не зависит от
# сети; сам pull выполняется здесь один раз.
#
# Запускать на хосте вручную:
#   - при первой сборке харнеса на этой машине;
#   - когда в Dockerfile'ах пилота меняется базовый образ (FROM ...).
# Файл scripts/base-images.tar гитигнорится (крупный, ~600 МБ).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Базовые образы 4 языков доклада (Python/JS/TS/Ruby) плюс alpine для
# node --test обёртки JS. Не-докладные языки (Go/Scala/OCaml) на DinD
# ещё не гоняются — добавить сюда, когда дойдут. ruby:3.3.12 и
# ruby:4.0.7 — для кампании Opus 5.5 × Ruby 3/4 (docs/opus-ruby/README.md).
IMAGES=(
  python:3.12-slim
  node:22-alpine
  ruby:3.3-slim
  ruby:3.3.12
  ruby:4.0.7
  alpine:3.20
)

echo "pull базовых образов..."
for img in "${IMAGES[@]}"; do
  docker pull --quiet "$img"
done

echo "docker save -> base-images.tar ..."
docker save "${IMAGES[@]}" -o base-images.tar

echo "готово: base-images.tar $(du -h base-images.tar | cut -f1)  (образы: ${IMAGES[*]})"
