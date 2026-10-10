#!/bin/bash
# Usage: ./run.sh before | after
# Runs every query 5 times with EXPLAIN (ANALYZE, BUFFERS), keeps the last plan (warm cache)
# and records the median execution time of the 5 runs.
set -e
cd "$(dirname "$0")"
. ../scripts/env.sh
MODE=$1
mkdir -p "plans/$MODE" results
FILES=(queries/*.sql)
[ "$MODE" = after ] && FILES+=(queries-after/*.sql)
: > "results/timings-$MODE.tsv"
for q in "${FILES[@]}"; do
  name=$(basename "$q" .sql)
  sql=$(grep -v '^--' "$q")
  times=()
  for i in 1 2 3 4 5; do
    plan=$(psql -X -At -c "EXPLAIN (ANALYZE, BUFFERS) $sql")
    times+=("$(echo "$plan" | sed -n 's/^Execution Time: \([0-9.]*\) ms/\1/p')")
  done
  { echo "-- $(sed -n '1p' "$q" | sed 's/^-- //')"; echo "-- mode: $MODE, run 5 of 5 (warm cache), $(date '+%Y-%m-%d %H:%M:%S %Z')"; echo; echo "$plan"; } > "plans/$MODE/$name.txt"
  median=$(printf '%s\n' "${times[@]}" | sort -n | sed -n '3p')
  printf '%s\t%s\t%s\n' "$name" "$median" "$(IFS=,; echo "${times[*]}")" >> "results/timings-$MODE.tsv"
  echo "$MODE  $name  median=${median} ms"
  if [ "$MODE" = after ]; then psql -X -c "$sql" > "results/$name.txt"; fi
done
