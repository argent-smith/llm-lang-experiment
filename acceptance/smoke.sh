#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
#
# Проверочные функции ниже (test_*, wait_healthz) вызываются косвенно
# через `check "имя" func` — статический анализ не видит этот вызов и
# считает их (и весь код внутри) недостижимыми/неиспользуемыми. SC2329 —
# современное имя этой проверки, SC2317 — старое (какое из двух сработает,
# зависит от версии shellcheck; на GitHub Actions это может быть версия
# старше той, что установлена локально).
#
# Языконезависимый acceptance-тест для реализаций Syncbox (SYNCBOX-SPEC.md).
# Работает через HTTP и вызов процесса — не заглядывает в код реализации,
# поэтому один и тот же скрипт годится для всех шести языков.
#
# Требует: bash, curl, python3 (только для разбора JSON), sha256sum или
# shasum, mktemp, base64. Всё это есть в стандартном Linux-окружении
# (CI, контейнер харнесса) и на macOS с Docker Desktop.
#
# Конвенция запуска (обязательна для каждой языковой реализации):
#   <impl-dir>/run-server --data-dir <path> --port <n>
#   <impl-dir>/run-client <push|pull|sync|status> <dir> --server <url>
# Оба файла — исполняемые обёртки поверх того, что нужно языку для
# запуска (интерпретатор, JAR, нативный бинарник) — внутри они разные,
# снаружи вызываются одинаково.
#
# Использование:
#   acceptance/smoke.sh <impl-dir> [port]

set -uo pipefail

IMPL_DIR="${1:?Использование: smoke.sh <impl-dir> [port]}"
PORT="${2:-18080}"
SERVER="http://127.0.0.1:${PORT}"

RUN_SERVER="$IMPL_DIR/run-server"
RUN_CLIENT="$IMPL_DIR/run-client"

if [[ ! -x "$RUN_SERVER" ]]; then
  echo "не найден исполняемый файл: $RUN_SERVER" >&2
  exit 1
fi
if [[ ! -x "$RUN_CLIENT" ]]; then
  echo "не найден исполняемый файл: $RUN_CLIENT" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
DATA_DIR="$WORKDIR/data"
SRC_DIR="$WORKDIR/src"
PULL_DIR="$WORKDIR/pull"
mkdir -p "$DATA_DIR" "$SRC_DIR" "$PULL_DIR"

SERVER_LOG="$WORKDIR/server.log"
SERVER_PID=""

PASS=0
FAIL=0
FAILED_NAMES=()

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

json_get() {
  # $1 = путь к JSON-файлу, $2 = python-выражение над переменной d
  python3 -c "
import json
d = json.load(open('$1'))
print($2)
"
}

check() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "PASS  $name"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "FAIL  $name"
  fi
}

# --- фикстуры: три файла разной природы ---
mkdir -p "$SRC_DIR/docs" "$SRC_DIR/nested/dir"
printf 'hello world\n' >"$SRC_DIR/hello.txt"
printf 'привет, мир\n' >"$SRC_DIR/docs/readme.txt"
head -c 4096 /dev/urandom >"$SRC_DIR/nested/dir/file.bin"

# --- запуск сервера ---
"$RUN_SERVER" --data-dir "$DATA_DIR" --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

wait_healthz() {
  # 150 * 0.2s = 30s — с запасом на холодный docker build (первый
  # запуск, ещё не кешированный слой с python:3.12-slim), а не только
  # на старт самого сервера.
  local i
  for i in $(seq 1 150); do
    if curl -fsS "$SERVER/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}
# тикет 1: /healthz, конфигурация через флаги
check "01-server-boots-and-healthz-responds" wait_healthz

# тикет 7: клиент push
test_push() {
  "$RUN_CLIENT" push "$SRC_DIR" --server "$SERVER" >/dev/null 2>&1
}
check "02-client-push-exits-zero" test_push

# тикет 3: GET /blobs со списком и метаданными
test_list_matches() {
  local tmp="$WORKDIR/list.json"
  curl -fsS "$SERVER/blobs" -o "$tmp" || return 1
  local n
  n=$(json_get "$tmp" "len(d)") || return 1
  [[ "$n" -eq 3 ]] || return 1
  local f
  for f in hello.txt docs/readme.txt nested/dir/file.bin; do
    local remote_hash local_hash
    remote_hash=$(json_get "$tmp" "next((b['sha256'] for b in d if b['key']=='$f'), '')") || return 1
    local_hash=$(sha256_of "$SRC_DIR/$f")
    [[ "$remote_hash" == "$local_hash" ]] || return 1
  done
}
check "03-server-list-matches-pushed-files" test_list_matches

# тикет 2: GET блоба побайтово совпадает
test_get_matches() {
  curl -fsS "$SERVER/blobs/hello.txt" -o "$WORKDIR/get-hello.txt" || return 1
  cmp -s "$WORKDIR/get-hello.txt" "$SRC_DIR/hello.txt"
}
check "04-server-get-returns-identical-bytes" test_get_matches

# тикет 2 (ошибочный путь): 404 на неизвестный ключ
test_404_unknown() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$SERVER/blobs/does-not-exist.txt")
  [[ "$code" == "404" ]]
}
check "05-server-404-on-unknown-key" test_404_unknown

# тикет 5: защита от directory traversal — и буквальный, и URL-encoded вид
test_traversal_rejected() {
  local code1 code2
  code1=$(curl --path-as-is -s -o /dev/null -w '%{http_code}' \
    -X PUT --data-binary 'x' "$SERVER/blobs/../evil.txt")
  code2=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT --data-binary 'x' "$SERVER/blobs/%2e%2e%2fevil.txt")
  [[ "$code1" == "400" && "$code2" == "400" ]]
}
check "06-server-rejects-path-traversal" test_traversal_rejected

# тикет 6: параллельные PUT по одному ключу не портят блоб
test_concurrent_put_atomic() {
  local key="race.txt"
  local pids=()
  local i
  for i in 1 2 3 4 5; do
    printf 'версия-%d-%s\n' "$i" "$(head -c 64 /dev/urandom | base64 | tr -d '\n')" \
      >"$WORKDIR/race-$i.txt"
    (curl -fsS -X PUT --data-binary "@$WORKDIR/race-$i.txt" "$SERVER/blobs/$key" >/dev/null) &
    pids+=($!)
  done
  local ok=0
  for p in "${pids[@]}"; do
    wait "$p" || ok=1
  done
  [[ $ok -eq 0 ]] || return 1
  curl -fsS "$SERVER/blobs/$key" -o "$WORKDIR/race-result.txt" || return 1
  local result_hash
  result_hash=$(sha256_of "$WORKDIR/race-result.txt")
  for i in 1 2 3 4 5; do
    if [[ "$(sha256_of "$WORKDIR/race-$i.txt")" == "$result_hash" ]]; then
      return 0
    fi
  done
  return 1
}
check "07-concurrent-put-does-not-corrupt-blob" test_concurrent_put_atomic

# тикет 10: клиент sync после локального изменения
echo 'изменено' >>"$SRC_DIR/hello.txt"
test_sync() {
  "$RUN_CLIENT" sync "$SRC_DIR" --server "$SERVER" >/dev/null 2>&1
}
check "08-client-sync-exits-zero" test_sync

test_sync_updated_remote() {
  curl -fsS "$SERVER/blobs/hello.txt" -o "$WORKDIR/get-hello-2.txt" || return 1
  cmp -s "$WORKDIR/get-hello-2.txt" "$SRC_DIR/hello.txt"
}
check "09-server-has-updated-content-after-sync" test_sync_updated_remote

# тикет 9: status — dry-run, ничего не меняет на сервере
echo 'ещё правка' >>"$SRC_DIR/hello.txt"
test_status_dry_run() {
  "$RUN_CLIENT" status "$SRC_DIR" --server "$SERVER" >/dev/null 2>&1 || return 1
  local tmp="$WORKDIR/get-hello-3.txt"
  curl -fsS "$SERVER/blobs/hello.txt" -o "$tmp" || return 1
  ! cmp -s "$tmp" "$SRC_DIR/hello.txt"
}
check "10-client-status-is-dry-run" test_status_dry_run
# вернуть согласованное состояние перед pull
"$RUN_CLIENT" sync "$SRC_DIR" --server "$SERVER" >/dev/null 2>&1 || true

# тикет 8: pull в чистую папку побайтово совпадает
test_pull() {
  "$RUN_CLIENT" pull "$PULL_DIR" --server "$SERVER" >/dev/null 2>&1 || return 1
  diff -rq "$SRC_DIR" "$PULL_DIR" >/dev/null
}
check "11-client-pull-matches-source-byte-for-byte" test_pull

# тикет 4: DELETE блоба, затем 404
test_delete() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$SERVER/blobs/hello.txt")
  [[ "$code" == "204" ]] || return 1
  code=$(curl -s -o /dev/null -w '%{http_code}' "$SERVER/blobs/hello.txt")
  [[ "$code" == "404" ]]
}
check "12-server-delete-then-404" test_delete

# тикет 11: клиент понятно сообщает об ошибке при недоступном сервере
#
# Хост в зоне .invalid принципиально не резолвится (RFC 2606) — тест не
# использует "плохой порт на 127.0.0.1", потому что в Docker-обёртке
# запуск клиента может сам поднимать сеть/сервис с заданным портом
# (см. run-server/run-client), из-за чего "порт без сервера" перестаёт
# быть недостижимым. Неразрешимое имя хоста недостижимо при любой такой
# обвязке — проверяется именно обработка ошибки клиентом, а не то,
# поднялся ли что-то по этому порту.
test_client_reports_unreachable_server() {
  "$RUN_CLIENT" push "$SRC_DIR" --server "http://this-host-does-not-exist.invalid:19999" \
    >"$WORKDIR/err.log" 2>&1
  local code=$?
  [[ $code -ne 0 && -s "$WORKDIR/err.log" ]]
}
check "13-client-nonzero-exit-and-message-on-unreachable-server" \
  test_client_reports_unreachable_server

echo
echo "Итог: $PASS пройдено, $FAIL провалено из $((PASS + FAIL))"
if [[ $FAIL -gt 0 ]]; then
  printf 'Провалено: %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
