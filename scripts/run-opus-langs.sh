#!/usr/bin/env bash
# Кампания Opus 5.5 × Python / JavaScript / TypeScript — те же языки, что в
# основной кампании, на конфигурации кампании Opus 5.5 × Ruby
# (scripts/run-opus-ruby.sh): тонкая обёртка над scripts/run-pilot-replay.sh.
# Промпты с закреплённым базовым образом — docs/opus-langs/prompts/
# (генерит scripts/make-pinned-prompts.py). Подробности и ограничения —
# docs/opus-langs/README.md.
#
#   PILOT_ACK_OPEN_WEB=1 scripts/run-opus-langs.sh [опции run-pilot-replay.sh]
#
# Например: --dry-run, --check-prompts, --force-clean,
# --resume --checkpoint <file>, --languages python-opus (только один язык).
# smoke по умолчанию info, как в основной кампании и в кампании Ruby
# (локальный смок на macOS нестабилен); переопределяется --smoke block.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PILOT_MODEL=claude-opus-5-5
# claude-opus-5-5 требует Claude Code от 2.1.280; 2.1.238 основной кампании отвечает 400.
export PILOT_CLAUDE_CODE_VERSION=2.1.288
export PILOT_EFFORT=high
export PILOT_DISALLOW_WEB_TOOLS=1

exec "$REPO_ROOT/scripts/run-pilot-replay.sh" \
  --languages "python-opus javascript-opus typescript-opus" \
  --prompt-dir "$REPO_ROOT/docs/opus-langs/prompts" \
  --smoke info \
  "$@"
