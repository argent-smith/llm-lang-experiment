# Shared helpers for the run-* wrappers; source it, don't execute it.
#
# compose_foreground SERVICE runs one compose service in the foreground and
# returns its exit code. Each call gets its own compose project, so several
# wrappers can run side by side, and the project is torn down on exit. SIGTERM,
# SIGINT and SIGHUP are forwarded to `docker compose up`, which stops the
# container gracefully: a plain `docker compose run` would exit on SIGTERM
# but leave the container running and holding its port.

syncbox_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

export SYNCBOX_UID="$(id -u)" SYNCBOX_GID="$(id -g)"

compose_foreground() {
  local service="$1"
  # Globals rather than locals: the traps below may run after we return.
  syncbox_compose=(docker compose --project-directory "$syncbox_root" -f "$syncbox_root/compose.yaml"
    -p "syncbox-$service-$$")

  "${syncbox_compose[@]}" build --quiet "$service"

  trap '"${syncbox_compose[@]}" down --timeout 10 >/dev/null 2>&1 || true' EXIT
  "${syncbox_compose[@]}" up --no-build --no-log-prefix --exit-code-from "$service" "$service" &
  syncbox_child=$!
  trap 'kill -TERM "$syncbox_child" 2>/dev/null || true' TERM INT HUP

  local status=0
  wait "$syncbox_child" || status=$?
  # A trapped signal interrupts `wait` while compose is still shutting down.
  while kill -0 "$syncbox_child" 2>/dev/null; do
    status=0
    wait "$syncbox_child" || status=$?
  done
  return "$status"
}
