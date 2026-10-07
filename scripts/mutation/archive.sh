#!/usr/bin/env bash
# Архивирует результаты mutant-прогона в docs/: всё, кроме рабочей копии
# кода (tree/) и строк прогресса в mutant.log.
#   scripts/mutation/archive.sh <out-dir> <docs/.../mutation/<ключ>>
set -euo pipefail
SRC="${1:?out-dir}"; DST="${2:?archive-dir}"
mkdir -p "$DST"
for f in summary.txt environment.txt subjects.txt subjects-sample.txt subject-mutations.txt patches.log baseline.log; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DST/$f"
done
grep -v '^progress: ' "$SRC/mutant.log" > "$DST/mutant.log"
ls "$DST"
