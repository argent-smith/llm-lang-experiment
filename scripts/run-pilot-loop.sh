#!/usr/bin/env bash
# Авто-итерирующий луп одного тикета: claude -p -> гейты -> при провале
# блокирующего гейта авто-построить фикс-промпт -> claude -p -> ... пока все
# блокирующие гейты не сойдутся или не исчерпан --max-iters.
#
#   scripts/run-pilot-loop.sh <pilot-dir> <initial-prompt-file> <out-prefix> [опции]
#
# Опции:
#   --max-iters <n>                 максимум вызовов claude -p (по умолч. 4)
#   --port <n>                      базовый порт для гейтов (по умолч. 18300)
#   --tests    <block|info|skip>    режим гейта штатных тестов   (по умолч. block)
#   --smoke    <block|info|skip>    режим acceptance-смока        (по умолч. info)
#   --contract <block|info|skip>    режим контракт-теста          (по умолч. block)
#
# Каждая итерация — отдельный вызов scripts/run-pilot-ticket.sh, то есть
# отдельная архивная директория в docs/pilot-runs/<lang>/ticket-<TAG>/<session>/
# и отдельная строка в журнале (журнал ведёт оператор; скрипт пишет
# <out-prefix>.loop.json со сводкой по итерациям для этого).
#
# Пишет:
#   <out-prefix>.iterK.json / .stderr.log   — результат K-го claude -p
#   <out-prefix>.iterK.gates/gates.json     — результат гейтов после итерации K
#   <out-prefix>.prompts/ticket-<TAG>-prompt.txt — промпт текущей итерации
#     (итерация 1 — копия исходного; 2+ — авто-построенный фикс-промпт)
#   <out-prefix>.loop.json                  — сводка: исход, итерации, суммы

set -uo pipefail

PILOT_DIR="${1:?Использование: run-pilot-loop.sh <pilot-dir> <initial-prompt-file> <out-prefix> [опции]}"
INITIAL_PROMPT="${2:?Использование: run-pilot-loop.sh <pilot-dir> <initial-prompt-file> <out-prefix> [опции]}"
OUT="${3:?Использование: run-pilot-loop.sh <pilot-dir> <initial-prompt-file> <out-prefix> [опции]}"
shift 3

PILOT_DIR="$(cd "$PILOT_DIR" && pwd)"
INITIAL_PROMPT="$(cd "$(dirname "$INITIAL_PROMPT")" && pwd)/$(basename "$INITIAL_PROMPT")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MAX_ITERS=4
PORT=18300
MODE_TESTS=block
MODE_SMOKE=info
MODE_CONTRACT=block
while [ $# -gt 0 ]; do
  case "$1" in
    --max-iters) MAX_ITERS="${2:?}"; shift 2 ;;
    --port)      PORT="${2:?}"; shift 2 ;;
    --tests)     MODE_TESTS="${2:?}"; shift 2 ;;
    --smoke)     MODE_SMOKE="${2:?}"; shift 2 ;;
    --contract)  MODE_CONTRACT="${2:?}"; shift 2 ;;
    *) echo "run-pilot-loop.sh: неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

# ticket-<TAG> из имени исходного промпта — тем же правилом, что и
# run-pilot-ticket.sh (см. TICKET_TAG там). Все итерации лупа идут под
# одним TAG, различаются session_id внутри архива.
STEM="$(basename "$INITIAL_PROMPT" | sed -E 's/-prompt\.txt$//; s/^\.//')"
case "$STEM" in
  ticket-*) : ;;
  *) echo "run-pilot-loop.sh: имя промпта должно быть [.]ticket-<N>[-<slug>]-prompt.txt, а не $(basename "$INITIAL_PROMPT")" >&2; exit 2 ;;
esac
TICKETS_DONE="$(echo "$STEM" | sed -E 's/^ticket-([0-9]+).*/\1/')"

PROMPT_DIR="${OUT}.prompts"
mkdir -p "$PROMPT_DIR"
CUR_PROMPT="$PROMPT_DIR/${STEM}-prompt.txt"
cp "$INITIAL_PROMPT" "$CUR_PROMPT"

jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print('' if v is None else v)" "$1" "$2" 2>/dev/null; }

ITER_RECORDS=""
outcome=""
iter=1

while [ "$iter" -le "$MAX_ITERS" ]; do
  echo "" >&2
  echo "################ ЛУП $STEM — итерация $iter/$MAX_ITERS ################" >&2

  ipfx="${OUT}.iter${iter}"
  "$REPO_ROOT/scripts/run-pilot-ticket.sh" "$PILOT_DIR" "$CUR_PROMPT" "$ipfx"
  claude_rc=$?

  session="$(jget "$ipfx.json" session_id)"
  is_error="$(jget "$ipfx.json" is_error)"
  api_status="$(jget "$ipfx.json" api_error_status)"
  cost="$(jget "$ipfx.json" total_cost_usd)"
  dur_ms="$(jget "$ipfx.json" duration_ms)"
  turns="$(jget "$ipfx.json" num_turns)"

  rec="{\"iter\": $iter, \"session\": \"$session\", \"claude_rc\": $claude_rc, \"is_error\": \"$is_error\", \"cost_usd\": \"$cost\", \"duration_ms\": \"$dur_ms\", \"num_turns\": \"$turns\""

  if [ "$claude_rc" -ne 0 ] || [ "$is_error" = "True" ] || [ "$is_error" = "true" ]; then
    outcome="сдался (инфра, не модель: claude_rc=$claude_rc api_error_status=$api_status)"
    ITER_RECORDS="${ITER_RECORDS}${ITER_RECORDS:+,}${rec}, \"gates\": null, \"note\": \"infra failure — цикл прерван\"}"
    echo "run-pilot-loop.sh: $outcome" >&2
    break
  fi

  # Агент правил внешний контракт (копии SYNCBOX-SPEC.md / syncbox-openapi.yaml
  # в директории пилота — одноразовые, run-pilot-ticket.sh перезаписывает их из
  # docs/ на каждый вызов, гейт проверяет каноническую схему). Это сигнал, что
  # провал гейта — на уровне спецификации, а не кода: агент не может это
  # починить изнутри, дальнейшие итерации только жгут бюджет. Останавливаемся
  # с явным исходом для оператора.
  spec_edited=""
  for f in SYNCBOX-SPEC.md syncbox-openapi.yaml; do
    if [ -f "$PILOT_DIR/$f" ] && ! diff -q "$REPO_ROOT/docs/$f" "$PILOT_DIR/$f" >/dev/null 2>&1; then
      spec_edited="$spec_edited $f"
      cp "$PILOT_DIR/$f" "${ipfx}.agent-edited-$f"
    fi
  done
  if [ -n "$spec_edited" ]; then
    outcome="сдался (агент правил спецификацию:$spec_edited — нужно решение оператора по контракту, не итерации)"
    ITER_RECORDS="${ITER_RECORDS}${ITER_RECORDS:+,}${rec}, \"gates\": null, \"note\": \"agent edited contract file(s):$spec_edited — правка сохранена в ${ipfx}.agent-edited-*\"}"
    echo "run-pilot-loop.sh: $outcome" >&2
    break
  fi

  gdir="${ipfx}.gates"
  "$REPO_ROOT/scripts/run-gates.sh" "$PILOT_DIR" "$gdir" \
    --port $((PORT + iter)) \
    --tests "$MODE_TESTS" --smoke "$MODE_SMOKE" --contract "$MODE_CONTRACT"
  gates_rc=$?

  gates_json_inline="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))" "$gdir/gates.json" 2>/dev/null || echo null)"
  ITER_RECORDS="${ITER_RECORDS}${ITER_RECORDS:+,}${rec}, \"gates\": ${gates_json_inline}}"

  if [ "$gates_rc" -eq 0 ]; then
    outcome="сошлось за $iter итераци$( [ "$iter" = 1 ] && echo ю || echo и )"
    echo "run-pilot-loop.sh: $outcome" >&2
    break
  fi

  next=$((iter + 1))
  if [ "$next" -gt "$MAX_ITERS" ]; then
    outcome="сдался (блокирующие гейты не сошлись за $MAX_ITERS итераций)"
    echo "run-pilot-loop.sh: $outcome" >&2
    break
  fi

  CUR_PROMPT="$PROMPT_DIR/${STEM}-prompt.txt"
  "$REPO_ROOT/scripts/build-fix-prompt.py" "$gdir/gates.json" \
    --tickets-done "$TICKETS_DONE" --iteration "$next" > "$CUR_PROMPT"
  echo "run-pilot-loop.sh: фикс-промпт для итерации $next -> $CUR_PROMPT" >&2
  iter=$next
done

{
  printf '{\n'
  printf '  "ticket_tag": "%s",\n' "$STEM"
  printf '  "pilot_dir": "%s",\n' "$PILOT_DIR"
  printf '  "max_iters": %s,\n' "$MAX_ITERS"
  printf '  "gate_modes": {"tests": "%s", "smoke": "%s", "contract": "%s"},\n' "$MODE_TESTS" "$MODE_SMOKE" "$MODE_CONTRACT"
  printf '  "outcome": "%s",\n' "$outcome"
  printf '  "iterations": [%s]\n' "$ITER_RECORDS"
  printf '}\n'
} > "${OUT}.loop.json"

echo "" >&2
echo "run-pilot-loop.sh: $outcome" >&2
echo "run-pilot-loop.sh: сводка -> ${OUT}.loop.json" >&2

case "$outcome" in
  сошлось*) exit 0 ;;
  *)        exit 1 ;;
esac
