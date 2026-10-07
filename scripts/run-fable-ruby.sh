#!/usr/bin/env bash
# Кампания Fable 5.1 × Ruby 3.3.12 / Ruby 4.0.7 — тонкая обёртка над
# scripts/run-pilot-replay.sh: фиксирует модель и effort, закрывает
# веб-инструменты агента и берёт промпты с зафиксированной версией Ruby
# из docs/fable-ruby/prompts/ (генерит scripts/make-pinned-prompts.py).
# Подробности и ограничения — docs/fable-ruby/README.md.
#
#   PILOT_ACK_OPEN_WEB=1 scripts/run-fable-ruby.sh [опции run-pilot-replay.sh]
#
# Например: --dry-run, --check-prompts, --resume --checkpoint <file>,
# --languages ruby4-fable (только одна версия).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PILOT_MODEL=claude-fable-5-1
# та же версия Claude Code, что в кампаниях Opus 5.5 (2.1.238 новые модели не поддерживает).
export PILOT_CLAUDE_CODE_VERSION=2.1.288
export PILOT_EFFORT=high
export PILOT_DISALLOW_WEB_TOOLS=1

exec "$REPO_ROOT/scripts/run-pilot-replay.sh" \
  --languages "ruby3-fable ruby4-fable" \
  --prompt-dir "$REPO_ROOT/docs/fable-ruby/prompts" \
  --smoke info \
  "$@"
