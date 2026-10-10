#!/bin/bash
# Runs every Portfolio 3 demo and writes the evidence/ files. Takes about 1 minute.
set -e
cd "$(dirname "$0")"; . ../scripts/env.sh
psql -X -f demos/01_commit.sql   > evidence/01-commit.txt 2>&1 || true
psql -X -f demos/02_rollback.sql > evidence/02-rollback.txt 2>&1 || true
demos/03_non_repeatable_read.sh > /dev/null
demos/04_lost_update.sh > /dev/null
demos/05_write_skew.sh > /dev/null
demos/06_deadlock.sh > /dev/null
demos/07_stress_pgbench.sh > /dev/null
demos/08_hotspot.sh > /dev/null
echo "Evidence written to $(pwd)/evidence:"; ls -1 evidence
