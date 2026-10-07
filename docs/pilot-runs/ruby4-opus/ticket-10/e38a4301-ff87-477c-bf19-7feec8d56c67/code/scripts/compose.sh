# Shared helpers for the run-* wrappers; source it, don't execute it.
#
# Each call gets its own compose project, so several wrappers can run side by
# side, and the project is torn down on exit. SIGTERM, SIGINT and SIGHUP stop
# the container gracefully.
#
# compose_foreground SERVICE runs one compose service in the foreground and
# returns its exit code. It uses `docker compose up` and forwards the signals
# to it: a plain `docker compose run` would exit on SIGTERM but leave the
# container running and holding its port.
#
# compose_run SERVICE [ARGS...] runs a one-off container of SERVICE with ARGS
# as its command and returns its exit code. Unlike `up`, which merges them
# into one log, `docker compose run` keeps the container's stdout and stderr
# apart. `down` does not see one-off containers, so the signals are delivered
# to the container itself (`docker compose kill`); `run` then exits with it.

syncbox_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

export SYNCBOX_UID="$(id -u)" SYNCBOX_GID="$(id -g)"

compose_foreground() {
  local service="$1"
  compose_prepare "$service"
  trap '"${syncbox_compose[@]}" down --timeout 10 >/dev/null 2>&1 || true' EXIT
  "${syncbox_compose[@]}" up --no-build --no-log-prefix --exit-code-from "$service" "$service" &
  syncbox_child=$!
  trap 'kill -TERM "$syncbox_child" 2>/dev/null || true' TERM INT HUP
  compose_wait
}

compose_run() {
  local service="$1"
  shift
  compose_prepare "$service"
  trap '"${syncbox_compose[@]}" kill "$syncbox_service" >/dev/null 2>&1 || true
        "${syncbox_compose[@]}" down --timeout 10 >/dev/null 2>&1 || true' EXIT
  "${syncbox_compose[@]}" run --rm --no-deps --no-TTY "$service" "$@" &
  syncbox_child=$!
  local signal
  for signal in TERM INT HUP; do
    trap '"${syncbox_compose[@]}" kill -s '"$signal"' "$syncbox_service" >/dev/null 2>&1 || true' "$signal"
  done
  compose_wait
}

# Sets up the compose command for SERVICE's own project and builds SERVICE.
compose_prepare() {
  # Globals rather than locals: the traps may run after the caller returns.
  syncbox_service="$1"
  syncbox_compose=(docker compose --project-directory "$syncbox_root" -f "$syncbox_root/compose.yaml"
    -p "syncbox-$syncbox_service-$$")
  # stdout is the service's alone: compose prints build hints there.
  "${syncbox_compose[@]}" build --quiet "$syncbox_service" >&2
}

# Waits for the compose process started in the background and returns its
# exit code.
compose_wait() {
  local status=0
  wait "$syncbox_child" || status=$?
  # A trapped signal interrupts `wait` while compose is still shutting down.
  while kill -0 "$syncbox_child" 2>/dev/null; do
    status=0
    wait "$syncbox_child" || status=$?
  done
  return "$status"
}
