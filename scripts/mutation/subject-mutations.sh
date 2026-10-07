#!/usr/bin/env bash
# Число мутаций на каждый субъект выборки (статический разбор, без прогона
# тестов) — чтобы считать score по субъектам и исключать тестовые помощники.
#   scripts/mutation/subject-mutations.sh <snapshot/code> <out-dir> <minitest|rspec>
# Пишет <out-dir>/subject-mutations.txt: "<субъект>\t<мутаций>".
set -euo pipefail
SNAP="$(cd "${1:?snapshot}" && pwd)"; OUT="$(cd "${2:?out-dir}" && pwd)"; INTEGRATION="${3:?minitest|rspec}"
TAG="syncbox-mutant:$(echo "$SNAP" | shasum | cut -c1-10)"
cp "$OUT/subjects-sample.txt" "$OUT/tree/.mutant-subjects-sample.txt"
WD="$(docker image inspect "$TAG" --format '{{.Config.WorkingDir}}')"; WD="${WD:-/app}"
docker run --rm -i -v "$OUT/tree:$WD" -w "$WD" \
  -e BUNDLE_GEMFILE="$WD/Gemfile.mutant" -e BUNDLE_FROZEN=false -e BUNDLE_DEPLOYMENT=false -e HOME=/tmp \
  --entrypoint /bin/sh "$TAG" -c "
    bundle install --quiet >/dev/null 2>&1
    while read -r s; do [ -n \"\$s\" ] || continue
      n=\$(bundle exec mutant environment show --usage opensource --integration $INTEGRATION --require ./mutant_boot -- \"\$s\" 2>/dev/null | awk '/^Mutations:/{print \$2}')
      printf '%s\t%s\n' \"\$s\" \"\${n:-?}\"
    done < .mutant-subjects-sample.txt" > "$OUT/subject-mutations.txt"
wc -l < "$OUT/subject-mutations.txt"
