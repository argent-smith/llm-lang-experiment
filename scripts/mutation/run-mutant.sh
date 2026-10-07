#!/usr/bin/env bash
# Mutation score реализации Syncbox на Ruby через mutant внутри её же
# Docker-образа. Код реализации не меняется: mutant и загрузчик тестов
# подключаются поверх (Gemfile.mutant, mutant_boot_*.rb).
#
#   scripts/mutation/run-mutant.sh <snapshot/code> <out-dir> <minitest|rspec> [опции mutant run]
#
# MUTANT_SAMPLE=<доля 0..1> — случайная выборка субъектов (методов) с seed 42:
# mutant гоняет мутации только по ним. Полный набор мутаций — тысячи, по
# 20–40 с на каждую выжившую (весь набор тестов), так что для сравнения
# берётся выборка; score считается по мутациям выбранных субъектов.
#
# Тесты и mutant запускаются от непривилегированного пользователя nobody, а
# не от root: тесты на права доступа (chmod 0555 и т. п.) под root
# пропускаются или ведут себя иначе (у Opus/Ruby 4 ensure-блок после skip
# падал с ENOENT) — compose реализаций тоже запускает их под uid хоста.
# Гемы ставятся root-ом, затем каталоги делаются доступными всем.
#
# Пишет в <out-dir>: environment.txt (число субъектов и мутаций всего),
# subjects.txt (все субъекты), subjects-sample.txt (выборка), baseline.log
# (прогон тестов без мутаций), patches.log, mutant.log (полный вывод),
# summary.txt.
set -euo pipefail
SNAP="$(cd "${1:?snapshot}" && pwd)"; OUT="${2:?out-dir}"; INTEGRATION="${3:?minitest|rspec}"; shift 3
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
WORK="$OUT/tree"; rm -rf "$WORK"; cp -R "$SNAP" "$WORK"
cp "$HERE/Gemfile.mutant" "$WORK/Gemfile.mutant"
cp "$HERE/mutant_boot_$INTEGRATION.rb" "$WORK/mutant_boot.rb"
cp "$HERE/sample_subjects.rb" "$WORK/sample_subjects.rb"
# Парсер mutant (parser gem) не принимает строковые литералы с байтами вне
# UTF-8 ("...\xFF".b) и падает на всём файле. В измерительной копии такой
# литерал заменяется на эквивалентное выражение; код реализации в архиве не
# меняется. Список правок — в patches.log.
python3 - "$WORK" <<'PY' | tee "$OUT/patches.log" >&2
import re, sys, glob
root = sys.argv[1]
for f in glob.glob(root + "/**/*.rb", recursive=True):
    src = open(f, encoding="utf-8", errors="surrogateescape").read()
    new = re.sub(r'\\xFF"\.b', '".b + [0xFF].pack("C")', src)
    if new != src:
        open(f, "w", encoding="utf-8", errors="surrogateescape").write(new)
        print("patched:", f[len(root) + 1:])
PY
TAG="syncbox-mutant:$(echo "$SNAP" | shasum | cut -c1-10)"
docker build -q -t "$TAG" "$WORK" >/dev/null
WD="$(docker image inspect "$TAG" --format '{{.Config.WorkingDir}}')"; WD="${WD:-/app}"
echo "образ $TAG, workdir $WD" >&2
docker run --rm -i --name "mutant-$(basename "$OUT")" \
  -v "$WORK:$WD" -w "$WD" \
  -e BUNDLE_GEMFILE="$WD/Gemfile.mutant" -e BUNDLE_FROZEN=false -e BUNDLE_DEPLOYMENT=false \
  -e MUTANT_COVER_LOG="$WD/.mutant-covers.txt" -e HOME=/tmp \
  --entrypoint /bin/sh "$TAG" -c "
    set -e
    bundle install --quiet
    chmod -R a+rwX /usr/local/bundle 2>/dev/null || true; chmod -R a+rwX $WD /tmp
    export BUNDLE_GEMFILE BUNDLE_FROZEN BUNDLE_DEPLOYMENT HOME MUTANT_COVER_LOG
    run_as() { su -m -s /bin/sh nobody -c \"\$1\"; }
    if [ $INTEGRATION = minitest ]; then run_as 'bundle exec rake test' > .mutant-baseline.log 2>&1; else run_as 'bundle exec rspec' > .mutant-baseline.log 2>&1; fi; echo \"baseline exit=\$?\" >> .mutant-baseline.log
    bundle exec mutant environment show --usage opensource --integration $INTEGRATION --require ./mutant_boot -- 'Syncbox*' > .mutant-env.txt 2>&1 || true
    bundle exec mutant environment subject list --usage opensource --integration $INTEGRATION --require ./mutant_boot -- 'Syncbox*' 2>/dev/null | grep -E '^Syncbox' > .mutant-subjects.txt || true
    ruby sample_subjects.rb ${MUTANT_SAMPLE:-1}
    run_as \"bundle exec mutant run --usage opensource --integration $INTEGRATION --require ./mutant_boot $* -- \$(cat .mutant-subjects-sample.txt | tr '\\n' ' ')\" > .mutant-run.log 2>&1; echo \"exit=\$?\" >> .mutant-run.log
  " || true
mv "$WORK/.mutant-env.txt" "$OUT/environment.txt" 2>/dev/null || true
mv "$WORK/.mutant-run.log" "$OUT/mutant.log" 2>/dev/null || true
mv "$WORK/.mutant-covers.txt" "$OUT/covers.txt" 2>/dev/null || true
mv "$WORK/.mutant-baseline.log" "$OUT/baseline.log" 2>/dev/null || true
mv "$WORK/.mutant-subjects.txt" "$OUT/subjects.txt" 2>/dev/null || true
mv "$WORK/.mutant-subjects-sample.txt" "$OUT/subjects-sample.txt" 2>/dev/null || true
tail -1 "$OUT/baseline.log" >&2
{ echo "субъектов всего: $(wc -l < "$OUT/subjects.txt" | tr -d ' '), в выборке: $(wc -l < "$OUT/subjects-sample.txt" | tr -d ' ')"; grep -E '^(Subjects|Mutations|Results|Kills|Alive|Timeouts|Coverage|Runtime|Killtime)|exit=' "$OUT/mutant.log" | tail -12; } | tee "$OUT/summary.txt"
