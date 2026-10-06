#!/usr/bin/env bash
# Прогоняет три чёрно-ящичных acceptance-гейта против реализации Syncbox и
# пишет <out-dir>/gates.json. Используется scripts/run-pilot-loop.sh как
# шаг «гейты» авто-итерирующего лупа (реализация -> гейты -> фикс-промпт ->
# повтор). Может вызываться и отдельно, для ручной проверки одного снапшота.
#
#   scripts/run-gates.sh <pilot-dir> <out-dir> [опции]
#
# Опции (режим гейта: block | info | skip):
#   --port <n>       базовый порт эфемерного сервера (по умолчанию 18200)
#   --tests <m>      штатные тесты через <pilot-dir>/run-tests   (по умолч. block)
#   --smoke <m>      acceptance/smoke.sh                          (по умолч. info)
#   --contract <m>   acceptance/contract-test.sh (schemathesis)  (по умолч. block)
#
# Код возврата: 0, если все гейты в режиме block прошли; 1 иначе. Гейты в
# режимах info/skip на код возврата не влияют, но всё равно попадают в
# gates.json.
#
# Контракт-гейт поднимает сервер НЕ через run-server, а напрямую
# `docker compose` с подсунутым docker-compose.override.yml, где /data —
# tmpfs: на macOS bind-mount данных идёт через virtiofs Docker Desktop,
# который недетерминированно отдаёт I/O-ошибки на экзотических именах
# файлов и делает schemathesis-прогон нестабильным (проверено: 2..7 из 8
# прогонов падали на идентичном входе). tmpfs убирает эту прослойку —
# фаззер бьёт по обычной Linux-fs, как это было бы на CI. smoke по-прежнему
# идёт через реальные run-server/run-client — ему нужен полный стенд.
#
# Порт сервера гейт берёт не только из SYNCBOX_PORT: спецификация не
# требует, чтобы compose-файл реализации читал именно эту переменную, и
# реализация с другими именами поднимается на своём порту (кампания
# Opus 5.5 × Ruby, тикет 1: сервер слушал 8080, гейт ждал $PORT и писал
# «сервер не поднялся»). Поэтому после `compose up` гейт пробует $PORT и
# хост-порты, которые сервис server реально опубликовал.
#
# Если `compose up server` сервер так и не дал (кампания Fable 5.1 × Ruby,
# тикет 1: порт задаётся только аргументом --port, который подставляет
# run-server, а CMD образа — 8080), гейт повторяет запуск через
# контрактный интерфейс — run-server --data-dir <tmp> --port $PORT — с тем
# же override-файлом на месте. Сам по себе run-server не годится: данные
# легли бы на bind-mount хоста, и на macOS экзотические имена ключей дают
# Errno::EILSEQ -> 500, которых нет на Linux-fs. Поэтому после запуска
# гейт проверяет, что /data контейнера — tmpfs (override подхвачен); на
# macOS без tmpfs гейт завершается ошибкой стенда, а не гоняет фаззер.

set -uo pipefail

PILOT_DIR="${1:?Использование: run-gates.sh <pilot-dir> <out-dir> [опции]}"
OUT_DIR="${2:?Использование: run-gates.sh <pilot-dir> <out-dir> [опции]}"
shift 2

PILOT_DIR="$(cd "$PILOT_DIR" && pwd)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PORT=18200
MODE_TESTS=block
MODE_SMOKE=info
MODE_CONTRACT=block

while [ $# -gt 0 ]; do
  case "$1" in
    --port)     PORT="${2:?}"; shift 2 ;;
    --tests)    MODE_TESTS="${2:?}"; shift 2 ;;
    --smoke)    MODE_SMOKE="${2:?}"; shift 2 ;;
    --contract) MODE_CONTRACT="${2:?}"; shift 2 ;;
    *) echo "run-gates.sh: неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

SCHEMATHESIS_BIN="$REPO_ROOT/.venv/bin/schemathesis"
GATES_JSON="$OUT_DIR/gates.json"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Портируемый таймаут (на macOS нет coreutils `timeout`; perl есть везде).
# fork+alarm в родителе: exec заменил бы процесс и снял бы обработчик ALRM.
# Код возврата 124 при срабатывании — как у GNU timeout.
with_timeout() {
  local secs="$1"; shift
  perl -e '
    my $s = shift @ARGV;
    my $pid = fork;
    if (!defined $pid) { exit 127 }
    if ($pid == 0) { exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; exit 124 };
    alarm $s;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$secs" "$@"
}

cleanup_docker() {
  docker ps -aq --filter "name=syncbox-gate-$PORT" --filter "name=syncbox-$PORT" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
  # Имя compose-проекта выбирает реализация (run-server); контейнер,
  # опубликовавший порт гейта, — наш в любом случае.
  docker ps -aq --filter "publish=$PORT" | xargs -r docker rm -f >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- tests gate
tests_status=skip; tests_exit=0; tests_tail=""
if [ "$MODE_TESTS" != "skip" ]; then
  if [ -x "$PILOT_DIR/run-tests" ]; then
    echo "== gate: tests (run-tests) ==" >&2
    if with_timeout 900 "$PILOT_DIR/run-tests" >"$OUT_DIR/gate-tests.log" 2>&1; then
      tests_status=pass
    else
      tests_exit=$?
      tests_status=fail
      [ "$tests_exit" = "124" ] && echo "(таймаут run-tests 900с)" >>"$OUT_DIR/gate-tests.log"
    fi
    tests_tail="$(tail -40 "$OUT_DIR/gate-tests.log")"
  else
    tests_status=error
    tests_tail="run-tests не найден или не исполняемый в $PILOT_DIR"
    echo "run-gates.sh: $tests_tail" >&2
  fi
fi

# ---------------------------------------------------------------- smoke gate
smoke_status=skip; smoke_passed=0; smoke_failed=0; smoke_total=0; smoke_failed_steps="[]"; smoke_tail=""
if [ "$MODE_SMOKE" != "skip" ]; then
  if [ -x "$PILOT_DIR/run-client" ] && [ -x "$PILOT_DIR/run-server" ]; then
    echo "== gate: smoke ==" >&2
    cleanup_docker
    if with_timeout 600 "$REPO_ROOT/acceptance/smoke.sh" "$PILOT_DIR" "$PORT" >"$OUT_DIR/gate-smoke.log" 2>&1; then
      smoke_status=pass
    else
      smoke_status=fail
    fi
    smoke_tail="$(tail -30 "$OUT_DIR/gate-smoke.log")"
    # "Итог: N пройдено, M провалено из T"
    line="$(grep -oE 'Итог: [0-9]+ пройдено, [0-9]+ провалено из [0-9]+' "$OUT_DIR/gate-smoke.log" || true)"
    if [ -n "$line" ]; then
      smoke_passed="$(echo "$line" | sed -E 's/.*Итог: ([0-9]+) пройдено.*/\1/')"
      smoke_failed="$(echo "$line" | sed -E 's/.*пройдено, ([0-9]+) провалено.*/\1/')"
      smoke_total="$(echo "$line"  | sed -E 's/.*из ([0-9]+).*/\1/')"
    fi
    # `|| true` у grep: при полностью зелёном смоке строк «Провалено:» нет,
    # grep выходит с 1, под pipefail срабатывал `|| echo '[]'` после уже
    # напечатанного python'ом [] — и в gates.json уходило "[]\n[]".
    smoke_failed_steps="$({ grep -oE '^Провалено: .*' "$OUT_DIR/gate-smoke.log" || true; } | sed 's/^Провалено: //' \
      | python3 -c 'import sys,json; s=sys.stdin.read().strip(); print(json.dumps([x for x in s.split() ] if s else []))' || echo '[]')"
    cleanup_docker
  else
    smoke_status=skip
    smoke_tail="run-client/run-server отсутствуют — smoke неприменим (клиентские тикеты ещё не сделаны)"
  fi
fi

# ------------------------------------------------------------- contract gate
contract_status=skip; contract_summary=""; contract_failures="[]"
if [ "$MODE_CONTRACT" != "skip" ]; then
  echo "== gate: contract (schemathesis, /data=tmpfs) ==" >&2
  if [ ! -x "$SCHEMATHESIS_BIN" ]; then
    contract_status=error
    contract_summary="schemathesis не установлен ($SCHEMATHESIS_BIN) — см. цель venv в Makefile"
    echo "run-gates.sh: $contract_summary" >&2
  else
    cleanup_docker
    OVERRIDE="$PILOT_DIR/docker-compose.override.yml"
    cat > "$OVERRIDE" <<'YML'
# Подставлен scripts/run-gates.sh на время контракт-гейта, снимается после.
# /data -> tmpfs, чтобы фаззер бил по обычной Linux-fs, а не по virtiofs
# Docker Desktop (недетерминированные I/O-ошибки на экзотических именах).
services:
  server:
    volumes: !reset []
    tmpfs:
      - /data
YML
    srv_log="$OUT_DIR/gate-contract-server.log"
    ( cd "$PILOT_DIR" \
        && SYNCBOX_DATA_DIR=/tmp/syncbox-gate-unused \
           SYNCBOX_DATA_DIR_HOST=/tmp/syncbox-gate-unused \
           SYNCBOX_PORT="$PORT" \
           COMPOSE_PROJECT_NAME="syncbox-gate-$PORT" \
           docker compose up --build server ) >"$srv_log" 2>&1 &
    srv_pid=$!

    # Порт сервера: $PORT (через SYNCBOX_PORT) или любой хост-порт, который
    # сервис server реально опубликовал (см. шапку).
    published_ports() {
      ( cd "$PILOT_DIR" && COMPOSE_PROJECT_NAME="syncbox-gate-$PORT" \
          docker compose ps --format json server 2>/dev/null ) \
        | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        items = json.loads(line)
    except ValueError:
        continue
    for item in items if isinstance(items, list) else [items]:
        for p in item.get("Publishers") or []:
            if p.get("PublishedPort"):
                print(p["PublishedPort"])
' 2>/dev/null | sort -u
    }
    up=0
    srv_port="$PORT"
    for _ in $(seq 1 200); do
      for cand in "$PORT" $(published_ports); do
        if curl -fsS "http://127.0.0.1:$cand/healthz" >/dev/null 2>&1; then
          up=1; srv_port="$cand"; break
        fi
      done
      [ "$up" -eq 1 ] && break
      sleep 0.3
    done
    [ "$up" -eq 1 ] && [ "$srv_port" != "$PORT" ] \
      && echo "run-gates.sh: сервер опубликован на порту $srv_port, а не $PORT — гейт идёт туда" >&2

    # Запасной запуск через run-server (см. шапку).
    contract_data=""
    stand_error=""
    if [ "$up" -ne 1 ] && [ -x "$PILOT_DIR/run-server" ]; then
      echo "run-gates.sh: compose up не дал сервер — повтор через run-server" >&2
      kill "$srv_pid" 2>/dev/null || true
      wait "$srv_pid" 2>/dev/null || true
      ( cd "$PILOT_DIR" && COMPOSE_PROJECT_NAME="syncbox-gate-$PORT" docker compose down -v >/dev/null 2>&1 ) || true
      cleanup_docker
      contract_data="$OUT_DIR/gate-contract-data"
      rm -rf "$contract_data"
      mkdir -p "$contract_data"
      { echo; echo "=== повтор через run-server ==="; } >>"$srv_log"
      "$PILOT_DIR/run-server" --data-dir "$contract_data" --port "$PORT" >>"$srv_log" 2>&1 &
      srv_pid=$!
      srv_port="$PORT"
      for _ in $(seq 1 300); do
        curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && { up=1; break; }
        sleep 0.3
      done
      if [ "$up" -eq 1 ]; then
        cid="$(docker ps -q --filter "publish=$PORT" | head -1)"
        tmpfs="$(docker inspect --format '{{json .HostConfig.Tmpfs}}' "$cid" 2>/dev/null || true)"
        if [[ "$tmpfs" != *'"/data"'* ]] && [ "$(uname -s)" = "Darwin" ]; then
          up=0
          stand_error="стенд: сервер поднят через run-server, но /data не на tmpfs (run-server не подхватил override) — на macOS контракт-прогон недетерминирован, гейт не запущен"
        fi
      fi
    fi

    if [ "$up" -ne 1 ]; then
      contract_status=error
      contract_summary="${stand_error:-сервер не поднялся за 60с (contract-гейт); хвост server-лога: $(tail -5 "$srv_log" | tr '\n' ' ')}"
    else
      # 3 прогона, гейт зелёный только если зелёны все три. Даже с tmpfs +
      # --generation-deterministic один язык (Python) флапает ~4/8 на
      # реальном граничном ключе: hypothesis то находит его в бюджете
      # генерации, то нет. Реальный дефект валит все три прогона; редкий
      # флап зелёного языка (JS/TS давали 8/8) при этом не блокирует.
      # Первый непройденный прогон запоминаем целиком — из него строится
      # фикс-промпт.
      contract_pass_runs=0
      contract_fail_runs=0
      contract_timeout=0
      first_fail_out=""
      for _cr in 1 2 3; do
        cout="$(with_timeout 240 "$SCHEMATHESIS_BIN" --config-file "$REPO_ROOT/acceptance/schemathesis.toml" \
                  run "$REPO_ROOT/docs/syncbox-openapi.yaml" \
                  --url "http://127.0.0.1:$srv_port" --generation-deterministic \
                  --checks not_a_server_error,status_code_conformance,response_schema_conformance 2>&1)"
        crc=$?
        if [ "$crc" -eq 0 ]; then
          contract_pass_runs=$((contract_pass_runs + 1))
        elif [ "$crc" -eq 124 ]; then
          contract_timeout=1
        else
          contract_fail_runs=$((contract_fail_runs + 1))
          [ -z "$first_fail_out" ] && first_fail_out="$cout"
        fi
      done
      { echo "=== последний прогон ==="; echo "$cout"; \
        [ -n "$first_fail_out" ] && { echo; echo "=== первый непройденный прогон ==="; echo "$first_fail_out"; }; } \
        > "$OUT_DIR/gate-contract.log"
      contract_summary="прогонов зелёных: $contract_pass_runs/3 (непройдено: $contract_fail_runs, таймаут: $contract_timeout)"
      if [ "$contract_pass_runs" -eq 3 ]; then
        contract_status=pass
      elif [ "$contract_timeout" -eq 1 ] && [ "$contract_fail_runs" -eq 0 ]; then
        contract_status=error
      else
        contract_status=fail
        contract_failures="$(printf '%s' "${first_fail_out:-$cout}" | python3 "$REPO_ROOT/scripts/parse-contract-failures.py" 2>/dev/null || echo '[]')"
      fi
    fi

    kill "$srv_pid" 2>/dev/null || true
    wait "$srv_pid" 2>/dev/null || true
    ( cd "$PILOT_DIR" && COMPOSE_PROJECT_NAME="syncbox-gate-$PORT" docker compose down -v >/dev/null 2>&1 ) || true
    rm -f "$OVERRIDE"
    cleanup_docker
    [ -n "$contract_data" ] && rm -rf "$contract_data"
  fi
fi

# --------------------------------------------------------------- gates.json
blocking_failed=""
gate_blocks() { [ "$1" = "block" ]; }
gate_ok()     { [ "$1" = "pass" ] || [ "$1" = "skip" ]; }
gate_blocks "$MODE_TESTS"    && ! gate_ok "$tests_status"    && blocking_failed="$blocking_failed tests"
gate_blocks "$MODE_SMOKE"    && ! gate_ok "$smoke_status"    && blocking_failed="$blocking_failed smoke"
gate_blocks "$MODE_CONTRACT" && ! gate_ok "$contract_status" && blocking_failed="$blocking_failed contract"
blocking_failed="$(echo "$blocking_failed" | xargs || true)"

overall=pass
[ -n "$blocking_failed" ] && overall=fail

{
  printf '{\n'
  printf '  "pilot_dir": %s,\n' "$(printf '%s' "$PILOT_DIR" | json_escape)"
  printf '  "gates": {\n'
  printf '    "tests": {"mode": "%s", "status": "%s", "exit": %s, "detail_tail": %s},\n' \
    "$MODE_TESTS" "$tests_status" "$tests_exit" "$(printf '%s' "$tests_tail" | json_escape)"
  printf '    "smoke": {"mode": "%s", "status": "%s", "passed": %s, "failed": %s, "total": %s, "failed_steps": %s, "detail_tail": %s},\n' \
    "$MODE_SMOKE" "$smoke_status" "${smoke_passed:-0}" "${smoke_failed:-0}" "${smoke_total:-0}" "$smoke_failed_steps" "$(printf '%s' "$smoke_tail" | json_escape)"
  printf '    "contract": {"mode": "%s", "status": "%s", "summary": %s, "failures": %s}\n' \
    "$MODE_CONTRACT" "$contract_status" "$(printf '%s' "$contract_summary" | json_escape)" "$contract_failures"
  printf '  },\n'
  printf '  "blocking_failed": %s,\n' "$(printf '%s' "$blocking_failed" | python3 -c 'import sys,json; s=sys.stdin.read().strip(); print(json.dumps(s.split() if s else []))')"
  printf '  "overall": "%s"\n' "$overall"
  printf '}\n'
} > "$GATES_JSON"

echo "run-gates.sh: $GATES_JSON  (overall=$overall${blocking_failed:+, blocked by: $blocking_failed})" >&2
[ "$overall" = "pass" ]
