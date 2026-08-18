#!/usr/bin/env bash
#
# Формальная контрактная проверка HTTP API Syncbox: по syncbox-openapi.yaml
# Schemathesis генерирует тест-кейсы (в том числе граничные и мусорные
# значения key) и бьёт ими в реальный сервер любой реализации — сервер
# не должен падать (5xx/обрыв соединения), а ответы должны соответствовать
# схеме (код, тип содержимого, форма JSON).
#
# Дополняет acceptance/smoke.sh, не заменяет его: smoke.sh проверяет
# конкретный сценарий использования (push/sync/pull дают ожидаемый
# результат), этот скрипт — что сервер не ломается на входных данных,
# которые сценарий не догадался попробовать.
#
# Не проверяет unsupported_method (реакцию на TRACE/OPTIONS и т. п.) —
# это вне контракта SYNCBOX-SPEC.md, эталонная реализация намеренно
# не занимается такими методами отдельно от стандартного поведения
# http.server.
#
# Требует: bash, curl, Python-пакет schemathesis (pip install schemathesis).
#
# Использование:
#   acceptance/contract-test.sh <impl-dir> [port]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SCHEMA="$REPO_ROOT/syncbox-openapi.yaml"

IMPL_DIR="${1:?Использование: contract-test.sh <impl-dir> [port]}"
PORT="${2:-18081}"
SERVER="http://127.0.0.1:${PORT}"
RUN_SERVER="$IMPL_DIR/run-server"

if [[ ! -x "$RUN_SERVER" ]]; then
  echo "не найден исполняемый файл: $RUN_SERVER" >&2
  exit 1
fi
if ! command -v schemathesis >/dev/null 2>&1; then
  echo "schemathesis не установлен (pip install schemathesis)" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

"$RUN_SERVER" --data-dir "$WORKDIR/data" --port "$PORT" >"$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!

ok=0
for _ in $(seq 1 50); do
  if curl -fsS "$SERVER/healthz" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 0.2
done
if [[ $ok -ne 1 ]]; then
  echo "сервер не поднялся за 10 секунд" >&2
  exit 1
fi

schemathesis run "$SCHEMA" \
  --url "$SERVER" \
  --checks not_a_server_error,status_code_conformance,response_schema_conformance
