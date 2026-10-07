#!/usr/bin/env bash
# Mutation score пяти Ruby-реализаций (финальные снимки после тикета 11):
# Sonnet 5 — все субъекты, Opus 5.5 и Fable 5.1 — выборка 25% субъектов
# (seed 42), 6 параллельных воркеров, таймаут мутации 120 с. Результаты —
# в pilot-runs-live/.mutation/<ключ>/, архив — в docs/opus-langs/mutation/<ключ>/.
#   scripts/mutation/run-campaign.sh [ключи…]   (по умолчанию все пять)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OUT=pilot-runs-live/.mutation; ARCHIVE=docs/opus-langs/mutation
declare -A INTEGRATION=([rb-s]=rspec [rb3-o]=minitest [rb3-f]=minitest [rb4-o]=minitest [rb4-f]=minitest)
declare -A SAMPLE=([rb-s]=1 [rb3-o]=0.25 [rb3-f]=0.25 [rb4-o]=0.25 [rb4-f]=0.25)
KEYS=("$@"); [ ${#KEYS[@]} -gt 0 ] || KEYS=(rb-s rb3-o rb3-f rb4-o rb4-f)
for k in "${KEYS[@]}"; do
  snap="$(python3 -c "import sys; sys.path.insert(0, 'scripts'); import campaignlib; print(campaignlib.snapshots('$k')['11'])")"
  echo "=== $k start $(date +%H:%M): $snap"
  MUTANT_SAMPLE="${SAMPLE[$k]}" scripts/mutation/run-mutant.sh "$snap" "$OUT/$k" "${INTEGRATION[$k]}" --jobs 6 --mutation-timeout 120
  scripts/mutation/subject-mutations.sh "$snap" "$OUT/$k" "${INTEGRATION[$k]}"
  scripts/mutation/archive.sh "$OUT/$k" "$ARCHIVE/$k"
  echo "=== $k done $(date +%H:%M)"
done
