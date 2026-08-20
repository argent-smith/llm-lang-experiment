#!/usr/bin/env bash
# Прогоняет code quality + code security по коду пилотного проекта —
# отдельно от цикла ревью тикета (см. CLAUDE.md, раздел «Метод»,
# таблица «CI-проверки»): результат логируется, но не возвращается
# модели и не влияет на «исход» тикета.
#
# По языку — пара инструментов из таблицы CLAUDE.md:
#   python -> ruff (quality) + bandit (security)
#   go     -> golangci-lint (quality) + gosec (security)
# Остальные языки таблицы (Ruby/Rubocop, JS-TS/ESLint, Scala/Scalafix,
# OCaml) пока не реализованы — добавлять по факту, когда эти языки
# дойдут до пилота, а не заранее вслепую.
#
# Использование:
#   scripts/run-code-quality.sh <python|go> <impl-dir> <output-prefix>
#
# Пишет:
#   <output-prefix>-quality.json
#   <output-prefix>-security.json
# Ничего не проваливает (все инструменты вызваны с "не падать на
# находках") — это сбор данных, не гейт.

set -euo pipefail

LANG_NAME="${1:?Использование: run-code-quality.sh <python|go> <impl-dir> <output-prefix>}"
IMPL_DIR="${2:?Использование: run-code-quality.sh <python|go> <impl-dir> <output-prefix>}"
OUTPUT_PREFIX="${3:?Использование: run-code-quality.sh <python|go> <impl-dir> <output-prefix>}"

IMPL_DIR="$(cd "$IMPL_DIR" && pwd)"
GOBIN="$(go env GOPATH 2>/dev/null)/bin"

case "$LANG_NAME" in
  python)
    command -v ruff >/dev/null 2>&1 || { echo "ruff не установлен (pip install ruff)" >&2; exit 1; }
    command -v bandit >/dev/null 2>&1 || { echo "bandit не установлен (pip install bandit)" >&2; exit 1; }
    ruff check --output-format json --exit-zero "$IMPL_DIR" >"${OUTPUT_PREFIX}-quality.json"
    bandit -r "$IMPL_DIR" -f json --exit-zero >"${OUTPUT_PREFIX}-security.json" 2>/dev/null
    ;;
  go)
    GOLANGCI="$GOBIN/golangci-lint"
    GOSEC="$GOBIN/gosec"
    [ -x "$GOLANGCI" ] || { echo "golangci-lint не установлен (go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest)" >&2; exit 1; }
    [ -x "$GOSEC" ] || { echo "gosec не установлен (go install github.com/securego/gosec/v2/cmd/gosec@latest)" >&2; exit 1; }
    # --show-stats=false: без него golangci-lint дописывает после JSON
    # человекочитаемую сводку в тот же stdout, ломая парсинг.
    (cd "$IMPL_DIR" && "$GOLANGCI" run --output.json.path stdout --issues-exit-code 0 --show-stats=false ./...) >"${OUTPUT_PREFIX}-quality.json"
    (cd "$IMPL_DIR" && "$GOSEC" -fmt json -no-fail -r ./...) >"${OUTPUT_PREFIX}-security.json"
    ;;
  *)
    echo "Язык '$LANG_NAME' пока не поддержан этим скриптом (только python, go)" >&2
    exit 1
    ;;
esac

echo "quality  -> ${OUTPUT_PREFIX}-quality.json"
echo "security -> ${OUTPUT_PREFIX}-security.json"
