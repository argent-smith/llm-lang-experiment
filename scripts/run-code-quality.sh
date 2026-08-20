#!/usr/bin/env bash
# Прогоняет code quality по коду пилотного проекта — отдельно от цикла
# ревью тикета (см. CLAUDE.md, раздел «Метод», таблица
# «CI-проверки»): результат логируется, но не возвращается модели и
# не влияет на «исход» тикета.
#
# Code security (bandit/gosec) пробовали и убрали 2026-08-20: сравнение
# находок между языками оказалось неинформативно для гипотезы
# эксперимента — числа отражали прежде всего разное покрытие правил
# между инструментами (bandit не ловит path traversal из коробки,
# gosec ловит), а не разницу в безопасности кода. Разбор —
# docs/PILOT-COMPARISON-python-go.md, раздел «Code quality / code
# security (исключено)».
#
# По языку — quality-инструмент из таблицы CLAUDE.md:
#   python -> ruff
#   go     -> golangci-lint
# Остальные языки таблицы (Ruby/Rubocop, JS-TS/ESLint, Scala/Scalafix,
# OCaml) пока не реализованы — добавлять по факту, когда эти языки
# дойдут до пилота, а не заранее вслепую.
#
# Использование:
#   scripts/run-code-quality.sh <python|go> <impl-dir> <output-prefix>
#
# Пишет:
#   <output-prefix>-quality.json
# Ничего не проваливает (инструмент вызван с "не падать на находках")
# — это сбор данных, не гейт.

set -euo pipefail

LANG_NAME="${1:?Использование: run-code-quality.sh <python|go> <impl-dir> <output-prefix>}"
IMPL_DIR="${2:?Использование: run-code-quality.sh <python|go> <impl-dir> <output-prefix>}"
OUTPUT_PREFIX="${3:?Использование: run-code-quality.sh <python|go> <impl-dir> <output-prefix>}"

IMPL_DIR="$(cd "$IMPL_DIR" && pwd)"
GOBIN="$(go env GOPATH 2>/dev/null)/bin"

case "$LANG_NAME" in
  python)
    command -v ruff >/dev/null 2>&1 || { echo "ruff не установлен (pip install ruff)" >&2; exit 1; }
    ruff check --output-format json --exit-zero "$IMPL_DIR" >"${OUTPUT_PREFIX}-quality.json"
    ;;
  go)
    GOLANGCI="$GOBIN/golangci-lint"
    [ -x "$GOLANGCI" ] || { echo "golangci-lint не установлен (go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest)" >&2; exit 1; }
    # --show-stats=false: без него golangci-lint дописывает после JSON
    # человекочитаемую сводку в тот же stdout, ломая парсинг.
    (cd "$IMPL_DIR" && "$GOLANGCI" run --output.json.path stdout --issues-exit-code 0 --show-stats=false ./...) >"${OUTPUT_PREFIX}-quality.json"
    ;;
  *)
    echo "Язык '$LANG_NAME' пока не поддержан этим скриптом (только python, go)" >&2
    exit 1
    ;;
esac

echo "quality -> ${OUTPUT_PREFIX}-quality.json"
