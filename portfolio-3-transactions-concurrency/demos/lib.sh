#!/bin/bash
# Helpers for running two (or more) concurrent psql sessions and merging their output into one
# timeline. Each output line is stamped with the time it appeared, relative to the start.
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/env.sh"
EVID="$(cd "$(dirname "${BASH_SOURCE[0]}")/../evidence" && pwd)"
TMP=$(mktemp -d)
START=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')

# session NAME SQLFILE [DELAY_SECONDS]  — starts a psql session in the background
session() {
  local name=$1 file=$2 delay=${3:-0}
  ( sleep "$delay"
    psql -X -a -v ON_ERROR_STOP=0 -f "$file" 2>&1 \
      | perl -MTime::HiRes=time -ne 'BEGIN{$|=1} printf "%.3f %s | %s", time, "'"$name"'", $_' > "$TMP/$name.log" ) &
}
# timeline TITLE OUTFILE — waits for all sessions, prints the merged, time-ordered log
timeline() {
  wait
  { echo "=== $1"; echo "    (t = seconds since start; A and B are separate database connections)"; echo
    cat "$TMP"/*.log | sort -s -n -k1,1 | sed -E 's#psql:[^ ]*/([ab]\.sql)#psql:\1#' | perl -ne 'BEGIN{$s='"$START"'} if (/^([\d.]+) (.*)$/s) { printf "t=%6.2fs  %s", $1-$s, $2 } else { print }'
    echo; } | tee -a "$2"
  rm -f "$TMP"/*.log
  START=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
}
# q "SQL" — run a quick statement outside the sessions (setup / checks), echoing it
q() { psql -X -c "$1"; }
