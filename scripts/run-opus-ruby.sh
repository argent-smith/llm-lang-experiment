#!/usr/bin/env bash
# Кампания Opus 5.5 × Ruby 3.3.12 / Ruby 4.0.7 — тонкая обёртка над
# scripts/run-pilot-replay.sh: фиксирует модель и effort, закрывает
# веб-инструменты агента и берёт промпты с зафиксированной версией Ruby
# из docs/opus-ruby/prompts/ (генерит scripts/make-pinned-prompts.py).
# Подробности и ограничения — docs/opus-ruby/README.md.
#
#   PILOT_ACK_OPEN_WEB=1 scripts/run-opus-ruby.sh [опции run-pilot-replay.sh]
#
# Например: --dry-run, --check-prompts, --resume --checkpoint <file>,
# --languages ruby4-opus (только одна версия).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PILOT_MODEL=claude-opus-5-5
# claude-opus-5-5 требует Claude Code от 2.1.280; 2.1.238 основной кампании отвечает 400.
export PILOT_CLAUDE_CODE_VERSION=2.1.288
export PILOT_EFFORT=high
export PILOT_DISALLOW_WEB_TOOLS=1

exec "$REPO_ROOT/scripts/run-pilot-replay.sh" \
  --languages "ruby3-opus ruby4-opus" \
  --prompt-dir "$REPO_ROOT/docs/opus-ruby/prompts" \
  "$@"
