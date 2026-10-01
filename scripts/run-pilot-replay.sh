#!/usr/bin/env bash
# Кампания перепрогона стартового бэклога тикетов на стабилизированном
# воркфлоу: для каждой ячейки (язык × тикет) вызывает
# scripts/run-pilot-loop.sh, ведёт персистентный чекпойнт и переживает
# оконный лимит использования (HTTP 429/529) — ждёт до сброса и повторяет
# ту же ячейку.
#
#   scripts/run-pilot-replay.sh [опции]
#
# Зачем: тикеты 1–7 пилота прошли ручным циклом на Docker-out-of-Docker,
# 8–9 — скриптованным лупом, но тоже DooD и до фикса метрики времени,
# только 10–11 — на целевой конфигурации (DinD, авто-луп, все гейты
# block). Эта кампания прогоняет весь бэклог под конфигурацией 10–11,
# чтобы страты S1/S2/S3 в docs/PILOT-COMPARISON-talk-languages.md
# схлопнулись в одну. Подробности — раздел «Перепрогон» в docs/RUNBOOK.md.
#
# Опции:
#   --languages "python javascript typescript ruby"   (по умолч. эти 4)
#   --tickets   "1 2 3 4 5 6 7 8 9 10 11"             (по умолч. 1..11)
#   --pilot-root <dir>     per-language pilot-директории (по умолч. pilot-runs-live)
#   --out-root   <dir>     логи кампании (по умолч. <pilot-root>/.replay-<UTC-timestamp>)
#   --checkpoint <file>    (по умолч. <out-root>/checkpoint.json)
#   --max-iters <n>        -> run-pilot-loop.sh (по умолч. 4)
#   --tests    <block|info|skip>   -> run-pilot-loop.sh (по умолч. block)
#   --smoke    <block|info|skip>   -> run-pilot-loop.sh (по умолч. block — тикеты 8–11 сделаны)
#   --contract <block|info|skip>   -> run-pilot-loop.sh (по умолч. block)
#   --max-429-retries <n>  пауз-ретраев на ячейку до жёсткого стопа (по умолч. 3)
#   --pause-margin-sec <n>  ждать сверх распарсенного времени сброса (по умолч. 300)
#   --fixed-pause-sec <n>   пауза, если время сброса не распарсилось (по умолч. 3600)
#   --max-pause-sec <n>     потолок одной паузы (по умолч. 21600 = 6ч)
#   --base-port <n>         база портов гейтов (по умолч. 18300; ячейка тикета N берёт base+N*20)
#   --resume                продолжить с чекпойнта: пропустить сошедшиеся ячейки,
#                           НЕ вайпать pilot-директории
#   --force-clean           перед первым тикетом каждого языка очистить его pilot-dir
#   --check-prompts         только разрешить и показать initial-промпты по ячейкам, не гонять
#   --dry-run               показать план ячеек и выйти
#
# Порядок: language-major, тикеты строго по возрастанию внутри языка.
# pilot-dir языка (<pilot-root>/<lang>) НЕ вайпается между его тикетами
# (тикет N строится на коде N-1). Между языками — свои директории.
#
# Промпт ячейки: initial-промпт тикета из архива
# docs/pilot-runs/<lang>/ticket-<N>/<канон-сессия>/prompt.txt (канон берётся
# из docs/pilot-runs/manifest.json; если там фикс-промпт — берётся
# старейшая сессия тикета с initial-промптом). Копируется в
# <pilot-root>/<lang>/.ticket-<N>-prompt.txt (маска .ticket-* исключена из
# архивации в run-pilot-ticket.sh).
#
# Чего скрипт НЕ делает: не трогает docs/pilot-runs/manifest.json. После
# зелёной кампании оператор прогоняет scripts/verify-replay.py по каждой
# новой сессии и обновляет manifest вручную (как для тикета 10) — команды
# печатаются в конце.
#
# Исход:
#   exit 0  — все ячейки converged
#   exit 1  — жёсткий стоп (429 сверх лимита ретраев / не-429 инфра-фейл /
#             харнесс неисправен / run-pilot-loop.sh не отдал .loop.json)
#   exit 2  — кампания дошла до конца, но часть ячеек не сошлась (spec-giveup
#             / no-converge) — данные записаны, нужен разбор оператором

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Защита от контаминации через открытый веб: см. lib-open-web-guard.sh.
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib-open-web-guard.sh"
require_open_web_ack || exit $?
MANIFEST="$REPO_ROOT/docs/pilot-runs/manifest.json"
CKPT_PY="$REPO_ROOT/scripts/replay-checkpoint.py"
LOOP_SH="$REPO_ROOT/scripts/run-pilot-loop.sh"

LANGUAGES="python javascript typescript ruby"
TICKETS="1 2 3 4 5 6 7 8 9 10 11"
PILOT_ROOT="$REPO_ROOT/pilot-runs-live"
OUT_ROOT=""
CHECKPOINT=""
MAX_ITERS=4
MODE_TESTS=block
MODE_SMOKE=block
MODE_CONTRACT=block
MAX_429_RETRIES=3
PAUSE_MARGIN_SEC=300
FIXED_PAUSE_SEC=3600
MAX_PAUSE_SEC=21600
BASE_PORT=18300
DO_RESUME=0
DO_FORCE_CLEAN=0
DO_CHECK_PROMPTS=0
DO_DRYRUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --languages)        LANGUAGES="${2:?}"; shift 2 ;;
    --tickets)          TICKETS="${2:?}"; shift 2 ;;
    --pilot-root)       PILOT_ROOT="$2"; shift 2 ;;
    --out-root)         OUT_ROOT="$2"; shift 2 ;;
    --checkpoint)       CHECKPOINT="$2"; shift 2 ;;
    --max-iters)        MAX_ITERS="${2:?}"; shift 2 ;;
    --tests)            MODE_TESTS="${2:?}"; shift 2 ;;
    --smoke)            MODE_SMOKE="${2:?}"; shift 2 ;;
    --contract)         MODE_CONTRACT="${2:?}"; shift 2 ;;
    --max-429-retries)  MAX_429_RETRIES="${2:?}"; shift 2 ;;
    --pause-margin-sec) PAUSE_MARGIN_SEC="${2:?}"; shift 2 ;;
    --fixed-pause-sec)  FIXED_PAUSE_SEC="${2:?}"; shift 2 ;;
    --max-pause-sec)    MAX_PAUSE_SEC="${2:?}"; shift 2 ;;
    --base-port)        BASE_PORT="${2:?}"; shift 2 ;;
    --resume)           DO_RESUME=1; shift ;;
    --force-clean)      DO_FORCE_CLEAN=1; shift ;;
    --check-prompts)    DO_CHECK_PROMPTS=1; shift ;;
    --dry-run)          DO_DRYRUN=1; shift ;;
    -h|--help)          sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "run-pilot-replay.sh: неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

# PREVIEW = только показать план/промпты, ничего не гонять и не писать
PREVIEW=0
{ [ "$DO_DRYRUN" -eq 1 ] || [ "$DO_CHECK_PROMPTS" -eq 1 ]; } && PREVIEW=1

mkdir -p "$PILOT_ROOT"
PILOT_ROOT="$(cd "$PILOT_ROOT" && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$OUT_ROOT" ] || OUT_ROOT="$PILOT_ROOT/.replay-$TS"
if [ "$PREVIEW" -ne 1 ]; then
  mkdir -p "$OUT_ROOT"
  OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
fi
[ -n "$CHECKPOINT" ] || CHECKPOINT="$OUT_ROOT/checkpoint.json"

for dep in "$CKPT_PY" "$LOOP_SH" "$MANIFEST"; do
  [ -e "$dep" ] || { echo "run-pilot-replay.sh: нет $dep" >&2; exit 2; }
done

log()  { echo "run-pilot-replay.sh: $*" >&2; }
rule() { echo "################ $* ################" >&2; }

jget() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print('' if v is None else v)" "$1" "$2" 2>/dev/null
}

# initial-промпт тикета начинается с одного из этих маркеров; фикс-промпты
# (ручные для тикета 7 и авто от build-fix-prompt.py) — с других.
is_initial_prompt() {
  head -c 400 "$1" 2>/dev/null | grep -qE '^(Мы начинаем новый проект Syncbox|Продолжаем проект Syncbox)'
}

resolve_prompt() {
  # печатает путь к initial-промпту для (lang=$1, ticket=$2); rc1 если не найден
  local lang="$1" n="$2" cano p
  cano="$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(m['languages'].get('$lang',{}).get('tickets',{}).get('$n',''))" 2>/dev/null)"
  if [ -n "$cano" ] && [ -f "$REPO_ROOT/$cano/prompt.txt" ] && is_initial_prompt "$REPO_ROOT/$cano/prompt.txt"; then
    echo "$REPO_ROOT/$cano/prompt.txt"; return 0
  fi
  # fallback: любая сессия тикета с initial-промптом (порядок глоба —
  # лексический по session-uuid, детерминированный)
  for p in "$REPO_ROOT"/docs/pilot-runs/"$lang"/ticket-"$n"/*/prompt.txt; do
    [ -f "$p" ] || continue
    if is_initial_prompt "$p"; then echo "$p"; return 0; fi
  done
  return 1
}

lang_dir_has_code() {
  # rc0, если в pilot-dir есть что-то кроме служебного (промпты, копии
  # спецификации, dotfiles)
  local d="$1"
  [ -d "$d" ] || return 1
  find "$d" -mindepth 1 -maxdepth 1 \
    ! -name '.*' ! -name 'SYNCBOX-SPEC.md' ! -name 'syncbox-openapi.yaml' \
    | grep -q .
}

wait_until() {
  # $1 = целевой epoch; урезано --max-pause-sec; не меньше 60 с
  local target="$1" now wait_s left resume_at
  now="$(date +%s)"
  wait_s=$((target - now))
  if [ "$wait_s" -gt "$MAX_PAUSE_SEC" ]; then
    log "распарсенная пауза ${wait_s}s > потолка ${MAX_PAUSE_SEC}s — жду только потолок, потом ретрай"
    wait_s="$MAX_PAUSE_SEC"
  fi
  [ "$wait_s" -ge 60 ] || wait_s=60
  resume_at=$(( now + wait_s ))
  log "пауза по лимиту: ~$((wait_s / 60)) мин, продолжу в $(date -u -d "@$resume_at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$resume_at" '+%Y-%m-%dT%H:%M:%SZ')"
  while :; do
    now="$(date +%s)"
    left=$((resume_at - now))
    [ "$left" -gt 0 ] || break
    [ $((left % 600)) -lt 60 ] && log "  ещё ~$((left / 60)) мин паузы"
    sleep "$( [ "$left" -lt 60 ] && echo "$left" || echo 60 )"
  done
}

# ------------------------------------------------------------------ preflight

if [ "$PREVIEW" -ne 1 ]; then
  if [ -f "$CHECKPOINT" ]; then
    if [ "$DO_RESUME" -ne 1 ]; then
      log "чекпойнт уже есть: $CHECKPOINT"
      log "  для продолжения — --resume; для новой кампании — --out-root <новый>"
      exit 2
    fi
    python3 "$CKPT_PY" clear-stopped "$CHECKPOINT"
  else
    CONFIG_JSON="$(python3 -c "import json,sys; print(json.dumps({'languages': sys.argv[1].split(), 'tickets': sys.argv[2].split(), 'gate_modes': {'tests': sys.argv[3], 'smoke': sys.argv[4], 'contract': sys.argv[5]}, 'max_iters': int(sys.argv[6])}, ensure_ascii=False))" "$LANGUAGES" "$TICKETS" "$MODE_TESTS" "$MODE_SMOKE" "$MODE_CONTRACT" "$MAX_ITERS")"
    python3 "$CKPT_PY" init "$CHECKPOINT" --config "$CONFIG_JSON"
  fi
fi

log "кампания: языки [$LANGUAGES] тикеты [$TICKETS]"
log "гейты: tests=$MODE_TESTS smoke=$MODE_SMOKE contract=$MODE_CONTRACT  max-iters=$MAX_ITERS"
log "out-root:    $OUT_ROOT"
log "checkpoint:  $CHECKPOINT"

CAMPAIGN_RC=0

for lang in $LANGUAGES; do
  PDIR="$PILOT_ROOT/$lang"
  mkdir -p "$PDIR"
  first_ticket_of_lang=1

  for n in $TICKETS; do
    cell="$lang/ticket-$n"

    if [ "$PREVIEW" -ne 1 ] && python3 "$CKPT_PY" is-done "$CHECKPOINT" "$lang" "$n"; then
      log "пропуск $cell — уже сошлось (чекпойнт)"
      first_ticket_of_lang=0
      continue
    fi

    prompt_src="$(resolve_prompt "$lang" "$n" || true)"
    if [ -z "$prompt_src" ]; then
      log "НЕ НАШЁЛ initial-промпт для $cell — положи его в pilot-runs/<lang>/ticket-<N>/*/prompt.txt или укажи вручную"
      python3 "$CKPT_PY" set-stopped "$CHECKPOINT" --reason "нет initial-промпта" --lang "$lang" --ticket "$n"
      exit 1
    fi

    if [ "$DO_CHECK_PROMPTS" -eq 1 ]; then
      echo "== $cell"
      echo "   src:  ${prompt_src#"$REPO_ROOT"/}"
      echo "   1-я стр: $(head -1 "$prompt_src")"
      first_ticket_of_lang=0
      continue
    fi

    if [ "$DO_DRYRUN" -eq 1 ]; then
      echo "ячейка $cell  <- ${prompt_src#"$REPO_ROOT"/}  порт $((BASE_PORT + n * 20))"
      first_ticket_of_lang=0
      continue
    fi

    # Очистка pilot-dir языка перед его ПЕРВЫМ тикетом в кампании. Применяется,
    # когда у языка в чекпойнте ещё НЕТ ни одной ячейки (свежий старт) — в т.ч.
    # под --resume: там уже пройденные языки отсеиваются по is-done выше, а
    # ещё не начатые всё равно должны стартовать с чистой директории, иначе
    # тикет 1 достраивает поверх старого кода (баг: до этого проверка целиком
    # пропускалась при --resume). Язык в процессе (есть записанные ячейки) не
    # трогаем — там накопленный код нужен следующим тикетам.
    lang_started=0
    python3 "$CKPT_PY" lang-started "$CHECKPOINT" "$lang" && lang_started=1
    if [ "$first_ticket_of_lang" -eq 1 ] && [ "$lang_started" -eq 0 ] && lang_dir_has_code "$PDIR"; then
      if [ "$DO_FORCE_CLEAN" -eq 1 ]; then
        log "--force-clean: очищаю $PDIR перед первым тикетом $lang"
        find "$PDIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      else
        log "pilot-dir $PDIR непуст, язык $lang ещё не начат — тикет 1 достроит поверх чужого кода"
        log "  очисти вручную или добавь --force-clean"
        python3 "$CKPT_PY" set-stopped "$CHECKPOINT" --reason "pilot-dir непуст на старте языка" --lang "$lang" --ticket "$n"
        exit 1
      fi
    fi

    mkdir -p "$OUT_ROOT/$lang"
    stage="$PDIR/.ticket-$n-prompt.txt"
    cp "$prompt_src" "$stage"

    retry=0
    while :; do
      rule "ЯЧЕЙКА $cell  (попытка $((retry + 1)))"
      opref="$OUT_ROOT/$lang/ticket-$n"
      "$LOOP_SH" "$PDIR" "$stage" "$opref" \
        --max-iters "$MAX_ITERS" \
        --tests "$MODE_TESTS" --smoke "$MODE_SMOKE" --contract "$MODE_CONTRACT" \
        --port $((BASE_PORT + n * 20))
      loop_json="$opref.loop.json"

      if [ ! -f "$loop_json" ]; then
        log "$cell: run-pilot-loop.sh не отдал .loop.json — жёсткий стоп"
        python3 "$CKPT_PY" set-stopped "$CHECKPOINT" --reason "нет .loop.json от лупа" --lang "$lang" --ticket "$n"
        exit 1
      fi

      status="$(python3 "$CKPT_PY" record-cell "$CHECKPOINT" "$lang" "$n" --loop-json "$loop_json" --retries "$retry")"
      outcome="$(jget "$loop_json" outcome)"
      log "$cell: status=$status  [$outcome]"

      case "$status" in
        converged)
          break
          ;;
        rate_limited)
          retry=$((retry + 1))
          if [ "$retry" -gt "$MAX_429_RETRIES" ]; then
            log "$cell: 429/529 — исчерпаны $MAX_429_RETRIES пауз-ретрая, жёсткий стоп (--resume после сброса)"
            python3 "$CKPT_PY" set-stopped "$CHECKPOINT" --reason "429 сверх лимита ретраев" --lang "$lang" --ticket "$n"
            exit 1
          fi
          last_iter=""
          _best_k=-1
          for _f in "$opref".iter*.json; do
            [ -f "$_f" ] || continue
            _k="${_f##*.iter}"; _k="${_k%.json}"
            case "$_k" in ''|*[!0-9]*) continue ;; esac
            if [ "$_k" -gt "$_best_k" ]; then _best_k="$_k"; last_iter="$_f"; fi
          done
          reset_epoch=""
          reset_iso="-"
          if [ -n "$last_iter" ]; then
            reset_epoch="$(python3 "$CKPT_PY" parse-reset "$last_iter" 2>"$opref.reset.log" || true)"
            reset_iso="$(cat "$opref.reset.log" 2>/dev/null || echo -)"
          fi
          if [ -z "$reset_epoch" ]; then
            reset_epoch=$(( $(date +%s) + FIXED_PAUSE_SEC ))
            log "$cell: время сброса не распарсилось — фиксированная пауза ${FIXED_PAUSE_SEC}s"
          fi
          target=$((reset_epoch + PAUSE_MARGIN_SEC))
          python3 "$CKPT_PY" record-pause "$CHECKPOINT" "$lang" "$n" \
            --reset-epoch "$reset_epoch" --reset-target "$reset_iso" \
            --source "${last_iter:-none}" --retry "$retry"
          wait_until "$target"
          ;;
        harness_invalid)
          log "$cell: харнесс неисправен (нет bash в образе? — docs/incidents/2026-09-03-dind-bash-missing/). Чинить харнесс, не ретраить."
          python3 "$CKPT_PY" set-stopped "$CHECKPOINT" --reason "харнесс неисправен" --lang "$lang" --ticket "$n"
          exit 1
          ;;
        infra_failure)
          log "$cell: не-429 инфра-фейл — нужны глаза (docker/харнесс). Жёсткий стоп."
          python3 "$CKPT_PY" set-stopped "$CHECKPOINT" --reason "не-429 инфра-фейл" --lang "$lang" --ticket "$n"
          exit 1
          ;;
        spec_level_giveup|did_not_converge|unknown)
          log "!!! $cell: НЕ СОШЛОСЬ ($status). Записано в чекпойнт, кампания продолжается."
          log "!!! Код этого тикета в $PDIR может быть неполным — тикет $((n + 1)) строится поверх него."
          CAMPAIGN_RC=2
          break
          ;;
        *)
          log "$cell: неизвестный статус '$status' — жёсткий стоп"
          python3 "$CKPT_PY" set-stopped "$CHECKPOINT" --reason "неизвестный статус $status" --lang "$lang" --ticket "$n"
          exit 1
          ;;
      esac
    done

    first_ticket_of_lang=0
  done
done

if [ "$PREVIEW" -eq 1 ]; then
  exit 0
fi

rule "КАМПАНИЯ ЗАВЕРШЕНА"
python3 "$CKPT_PY" summary "$CHECKPOINT" >&2

cat >&2 <<EOF

Дальше вручную (как для тикета 10):
  1. По каждой новой сошедшейся сессии:
       scripts/verify-replay.py docs/pilot-runs/<lang>/ticket-<N>/<session>
  2. Обновить docs/pilot-runs/manifest.json: languages.<lang>.tickets.<N> -> новый путь;
     старые директории оставить, добавить пометку _ticket_<N>_replayed_$TS.
  3. Пересобрать docs/PILOT-COMPARISON-talk-languages.md (страта теперь одна) и
     дописать строки в docs/EXPERIMENT-LOG.md.
  Чекпойнт: $CHECKPOINT
EOF

exit "$CAMPAIGN_RC"
