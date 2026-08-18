# shellcheck shell=bash
# Общее для run-server и run-client. Не исполняемый сам по себе —
# подключается через `source`.

IMPL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$IMPL_DIR/docker-compose.yml"

project_for_port() {
  echo "syncbox-reference-impl-$1"
}

compose() {
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"
}
