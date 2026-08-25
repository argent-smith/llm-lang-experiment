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
# По языку — quality-инструмент, с явным, версионируемым конфигом и
# закреплённой версией инструмента в собственном локальном sandbox'е
# scripts/code-quality-configs/<язык>/ — в конвенциональном для языка
# стиле (venv для Python, GOPATH/bin для Go, Bundler для Ruby, npm для
# JavaScript/TypeScript), не глобальный инструмент и не голый дефолт.
# Пилотный агент эти файлы не видит — не конфиг самого пилотного
# проекта.
#
#   python     -> ruff (venv)                  + code-quality-configs/python/ruff.toml
#   go         -> golangci-lint (GOPATH)        + code-quality-configs/go/golangci.yml
#   ruby       -> rubocop + reek (bundle exec)  + code-quality-configs/ruby/.rubocop.yml
#   javascript -> eslint + sonarjs (npm)        + code-quality-configs/javascript/eslint.config.js
#   typescript -> eslint + typescript-eslint + sonarjs (npm) + code-quality-configs/typescript/eslint.config.js
#
# JavaScript и TypeScript — конвенционально разные наборы тулинга
# (typescript-eslint не имеет смысла в проекте без TypeScript), поэтому
# два отдельных конфига, не общий "js" — см. CLAUDE.md, «Языки
# доклада»: с разделения JS/TS на два самостоятельных пилота это два
# разных языка эксперимента, не один слот на двоих.
#
# Наборы правил в конфигах — конвенциональные стартовые точки для
# новых проектов на каждом языке (подтверждено независимо для каждого,
# не выбрано произвольно — обоснование и источники см. в самих файлах
# конфигов). Архитектурные/структурные находки (сложность, длина,
# code smell — LongParameterList, FeatureEnvy и т. п.) сознательно
# включены везде, не только в Ruby: ruff — категории C90/PLR,
# golangci-lint — gocyclo/funlen/dupl, reek — отдельным инструментом
# (не покрывается rubocop), eslint — eslint-plugin-sonarjs.
#
# Scala (Scalafix) и OCaml — намеренно не реализованы: Scalafix
# нуждается в project-specific semanticdb-настройке, которую нельзя
# осмысленно подготовить заранее без реального пилотного проекта;
# у OCaml на 2026 год нет общепринятого линтера вообще (ocamllint/
# ocp-lint мертвы, замены не появилось — подтверждено поиском, не
# предположено). Оба — добавлять/решать по факту, когда эти языки
# дойдут до пилота.
#
# Использование:
#   scripts/run-code-quality.sh <python|go|ruby|javascript|typescript> <impl-dir> <output-prefix>
#
# Пишет:
#   <output-prefix>-quality.json
# Ничего не проваливает (инструмент вызван с "не падать на находках")
# — это сбор данных, не гейт.

set -euo pipefail

LANG_NAME="${1:?Использование: run-code-quality.sh <python|go|ruby|javascript|typescript> <impl-dir> <output-prefix>}"
IMPL_DIR="${2:?Использование: run-code-quality.sh <python|go|ruby|javascript|typescript> <impl-dir> <output-prefix>}"
OUTPUT_PREFIX="${3:?Использование: run-code-quality.sh <python|go|ruby|javascript|typescript> <impl-dir> <output-prefix>}"

IMPL_DIR="$(cd "$IMPL_DIR" && pwd)"
GOBIN="$(go env GOPATH 2>/dev/null)/bin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/scripts/code-quality-configs"

case "$LANG_NAME" in
  python)
    RUFF="$CONFIG_DIR/python/.venv/bin/ruff"
    [ -x "$RUFF" ] || { echo "ruff не установлен в sandbox (cd $CONFIG_DIR/python && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt)" >&2; exit 1; }
    "$RUFF" check --config "$CONFIG_DIR/python/ruff.toml" --output-format json --exit-zero "$IMPL_DIR" >"${OUTPUT_PREFIX}-quality.json"
    ;;
  go)
    GOLANGCI="$GOBIN/golangci-lint"
    [ -x "$GOLANGCI" ] || { echo "golangci-lint не установлен (go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.13.1)" >&2; exit 1; }
    # --show-stats=false: без него golangci-lint дописывает после JSON
    # человекочитаемую сводку в тот же stdout, ломая парсинг.
    (cd "$IMPL_DIR" && "$GOLANGCI" run --config "$CONFIG_DIR/go/golangci.yml" --output.json.path stdout --issues-exit-code 0 --show-stats=false ./...) >"${OUTPUT_PREFIX}-quality.json"
    ;;
  ruby)
    [ -d "$CONFIG_DIR/ruby/vendor/bundle" ] || { echo "rubocop/reek не установлены в sandbox (cd $CONFIG_DIR/ruby && bundle config set --local path 'vendor/bundle' && bundle install)" >&2; exit 1; }
    # rubocop (стиль/lint, конвенциональный дефолт + Metrics) и reek
    # (архитектурные code smell — LongParameterList, FeatureEnvy и
    # т.п., то, что rubocop не покрывает) — два разных инструмента,
    # объединяем в один JSON с ключом по имени инструмента.
    # exit 1 у rubocop и exit 2 у reek значат "есть находки", не
    # ошибка вызова — падаем только на другие коды.
    set +e
    (cd "$CONFIG_DIR/ruby" && bundle exec rubocop --config .rubocop.yml --format json --force-exclusion "$IMPL_DIR") >/tmp/rubocop-out.json
    rubocop_rc=$?
    (cd "$CONFIG_DIR/ruby" && bundle exec reek --format json "$IMPL_DIR") >/tmp/reek-out.json
    reek_rc=$?
    set -e
    [ "$rubocop_rc" -le 1 ] || { echo "rubocop завершился с кодом $rubocop_rc (не просто находки)" >&2; exit "$rubocop_rc"; }
    [ "$reek_rc" -eq 0 ] || [ "$reek_rc" -eq 2 ] || { echo "reek завершился с кодом $reek_rc (не просто находки)" >&2; exit "$reek_rc"; }
    python3 -c "
import json
rubocop = json.load(open('/tmp/rubocop-out.json'))
reek = json.load(open('/tmp/reek-out.json'))
json.dump({'rubocop': rubocop, 'reek': reek}, open('${OUTPUT_PREFIX}-quality.json', 'w'), ensure_ascii=False, indent=2)
"
    rm -f /tmp/rubocop-out.json /tmp/reek-out.json
    ;;
  javascript|typescript)
    # JavaScript и TypeScript — два отдельных sandbox'а с разным
    # набором тулинга (typescript-eslint только у TypeScript), но
    # одинаковый способ вызова — общая ветка на оба имени.
    LANG_CONFIG_DIR="$CONFIG_DIR/$LANG_NAME"
    [ -d "$LANG_CONFIG_DIR/node_modules" ] || { echo "eslint не установлен в sandbox (cd $LANG_CONFIG_DIR && npm install)" >&2; exit 1; }
    # ESLint по умолчанию отказывается линтить файлы вне каталога
    # своего конфига ("outside of base path") — запускаем из целевой
    # директории, конфиг передаём абсолютным путём, как для остальных
    # языков. exit 1 значит "есть находки", падаем только на 2+
    # (fatal error — битый конфиг, краш).
    set +e
    (cd "$IMPL_DIR" && npx --prefix "$LANG_CONFIG_DIR" eslint --config "$LANG_CONFIG_DIR/eslint.config.js" --format json --no-warn-ignored .) >"${OUTPUT_PREFIX}-quality.json"
    rc=$?
    set -e
    [ "$rc" -le 1 ] || { echo "eslint завершился с кодом $rc (не просто находки)" >&2; exit "$rc"; }
    ;;
  *)
    echo "Язык '$LANG_NAME' пока не поддержан этим скриптом (python, go, ruby, javascript, typescript — Scala/OCaml см. комментарий в начале файла)" >&2
    exit 1
    ;;
esac

echo "quality -> ${OUTPUT_PREFIX}-quality.json"
