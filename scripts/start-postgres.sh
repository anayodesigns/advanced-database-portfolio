#!/bin/bash
# Initialise (first run only) and start the PostgreSQL primary on port 5433.
set -e
. "$(dirname "$0")/env.sh"
mkdir -p "$VAR/pg" "$VAR/log"
if [ ! -d "$VAR/pg/primary" ]; then
  initdb -D "$VAR/pg/primary" -U postgres --auth=trust -E UTF8 --locale=C
fi
pg_ctl -D "$VAR/pg/primary" -o "-p 5433" -l "$VAR/log/pg-primary.log" status >/dev/null 2>&1 \
  || pg_ctl -D "$VAR/pg/primary" -o "-p 5433" -l "$VAR/log/pg-primary.log" -w start
psql -d postgres -Atc "SELECT 'PostgreSQL up: ' || version();"
