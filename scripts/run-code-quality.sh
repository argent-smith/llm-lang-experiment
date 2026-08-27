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
#   scala      -> scalafix (sbt --addPluginSbtFile, host-local sbt) + code-quality-configs/scala/.scalafix.conf
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
# включены везде, где у инструмента есть для этого правила, не только
# в Ruby: ruff — категории C90/PLR, golangci-lint — gocyclo/funlen/dupl,
# reek — отдельным инструментом (не покрывается rubocop), eslint —
# eslint-plugin-sonarjs. Scalafix — исключение: у встроенных правил
# такого класса нет вообще, не пробел этого скрипта (см. ветку scala
# ниже и scripts/code-quality-configs/scala/.scalafix.conf).
#
# Scala реализована 2026-08-27, по факту первого реального пилота
# (Scala 3.3.8 + sbt + munit, единственный модуль server/) — до этого
# осознанно не готовилась вслепую, см. CLAUDE.md, «Сначала пилот».
#
# OCaml — по-прежнему не реализован: на 2026 год нет общепринятого
# линтера вообще (ocamllint/ocp-lint мертвы, замены не появилось —
# подтверждено поиском, не предположено). Решать по факту, когда OCaml
# дойдёт до пилота.
#
# Использование:
#   scripts/run-code-quality.sh <python|go|ruby|javascript|typescript|scala> <impl-dir> <output-prefix>
#
# Пишет:
#   <output-prefix>-quality.json
# Ничего не проваливает (инструмент вызван с "не падать на находках")
# — это сбор данных, не гейт.

set -euo pipefail

LANG_NAME="${1:?Использование: run-code-quality.sh <python|go|ruby|javascript|typescript|scala> <impl-dir> <output-prefix>}"
IMPL_DIR="${2:?Использование: run-code-quality.sh <python|go|ruby|javascript|typescript|scala> <impl-dir> <output-prefix>}"
OUTPUT_PREFIX="${3:?Использование: run-code-quality.sh <python|go|ruby|javascript|typescript|scala> <impl-dir> <output-prefix>}"

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
  scala)
    # Scalafix — принципиально другая архитектура вызова, чем у
    # остальных языков: семантические правила (RemoveUnused,
    # OrganizeImports, NoAutoTupling) требуют SemanticDB, который
    # генерируется ТОЛЬКО компиляцией самого пилотного проекта — нет
    # способа проверить готовый .scala-файл извне, как ruff/rubocop/
    # eslint проверяют файлы без участия сборки проекта. Поэтому:
    #   - плагин sbt-scalafix подключается через
    #     `sbt --addPluginSbtFile=<наш plugins.sbt>` — штатная,
    #     документированная фича sbt (DefaultCommands, подтверждено
    #     через DeepWiki по исходникам sbt/sbt) для инъекции плагина
    #     на один вызов, без правки project/plugins.sbt пилота.
    #     Альтернатива (глобальный ~/.sbt/1.0/plugins через --sbt-dir)
    #     проверена и отклонена — на этой sbt-инсталляции --sbt-dir
    #     не подхватывает плагины из редиректнутого пути (расхождение
    #     с документацией флага, подтверждено эмпирически дважды), а
    #     трогать реальный ~/.sbt пользователя ради sandbox'а нельзя.
    #   - `ThisBuild/scalafixConfig` и `-Wunused:all` (обязателен для
    #     RemoveUnused/OrganizeImports на Scala 3.3.4+, без него sbt
    #     падает `scalafix.sbt.InvalidArgument` ещё до запуска правил)
    #     задаются через `set` — тоже эфемерно, session-only, не
    #     пишется в build.sbt пилота.
    #   - `scalafixEnable` включает SemanticDB для текущей sbt-сессии
    #     (документировано как временное, session-only, тоже не
    #     трогает build.sbt).
    # У Scalafix нет встроенного JSON-вывода (в отличие от
    # ruff/rubocop/eslint/golangci-lint) — только текст, парсится
    # parse-scalafix-output.py в два вида находок: построчные
    # диагностики линтер-правил (DisableSyntax) и unified-diff на файл
    # от rewrite-правил (OrganizeImports и т.д., без атрибуции по
    # конкретному правилу внутри diff — несколько rewrite-правил
    # мержатся в один diff на файл в режиме --check).
    #
    # Архитектурные/структурные находки (сложность, длина метода —
    # то, что есть у ruff/golangci-lint/reek) сознательно не
    # покрыты — у встроенных правил Scalafix такого класса нет; это
    # открытый пробел метода, не недосмотр этого скрипта (CLAUDE.md,
    # таблица code quality — колонка для Scala отмечена «—»).
    LANG_CONFIG_DIR="$CONFIG_DIR/scala"
    SBT_PROJECT_DIR="$(dirname "$(find "$IMPL_DIR" -maxdepth 3 -name build.sbt | head -1)")"
    [ -n "$SBT_PROJECT_DIR" ] && [ -d "$SBT_PROJECT_DIR" ] || { echo "build.sbt не найден внутри $IMPL_DIR (глубина поиска 3)" >&2; exit 1; }
    set +e
    (cd "$SBT_PROJECT_DIR" && sbt --addPluginSbtFile="$LANG_CONFIG_DIR/plugins.sbt" \
      "set ThisBuild/scalafixConfig := Some(file(\"$LANG_CONFIG_DIR/.scalafix.conf\"))" \
      "set ThisBuild/scalacOptions += \"-Wunused:all\"" \
      scalafixEnable \
      "scalafixAll --check") >/tmp/scalafix-raw.txt 2>&1
    rc=$?
    set -e
    python3 "$LANG_CONFIG_DIR/parse-scalafix-output.py" <"/tmp/scalafix-raw.txt" >"${OUTPUT_PREFIX}-quality.json"
    rm -f /tmp/scalafix-raw.txt
    if [ "$rc" -ne 0 ]; then
      found=$(python3 -c "import json; d=json.load(open('${OUTPUT_PREFIX}-quality.json')); print(len(d['scalafix']['diagnostics'])+len(d['scalafix']['rewrite_diffs']))")
      [ "$found" -gt 0 ] || { echo "scalafixAll завершился кодом $rc, но находок не распарсено — вероятно реальная ошибка, не просто находки (см. \"raw_stdout\" в ${OUTPUT_PREFIX}-quality.json)" >&2; exit "$rc"; }
    fi
    ;;
  *)
    echo "Язык '$LANG_NAME' пока не поддержан этим скриптом (python, go, ruby, javascript, typescript, scala — OCaml см. комментарий в начале файла)" >&2
    exit 1
    ;;
esac

echo "quality -> ${OUTPUT_PREFIX}-quality.json"
