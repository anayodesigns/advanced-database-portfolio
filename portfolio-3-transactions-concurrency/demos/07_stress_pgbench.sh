#!/bin/bash
# Demo 07 — Concurrency stress test with pgbench. Same workload for every run: 20,000 payment
# attempts on random trips from a pool of 19,999 (so ~37% of attempts collide with an already-paid
# trip). 1, 4 and 16 concurrent clients. Checks that no money is created or destroyed.
cd "$(dirname "$0")"; . ./lib.sh
OUT="$EVID/07-stress-pgbench.txt"; : > "$OUT"
{
for C in 1 4 16; do
  psql -X -q -f reset_stress.sql
  echo "=== Invariants BEFORE ($C client(s))"; psql -X -q -f invariants.sql
  echo "=== pgbench: $C client(s) x $((20000 / C)) transactions, READ COMMITTED, pay_trip() with ordered row locks"
  T0=$(perl -MTime::HiRes=time -e 'print time')
  pgbench -n -c $C -j $(( C < 4 ? C : 4 )) -t $((20000 / C)) -f pay_trip.pgbench 2>&1 | grep -E "processed|failed|latency average|^tps"
  T1=$(perl -MTime::HiRes=time -e 'print time')
  echo "=== Invariants AFTER ($C client(s))"; psql -X -q -f invariants.sql
  PAID=$(psql -X -At -c "SELECT count(*) FROM swiftmove.payment p JOIN swiftmove.stress_trip s USING (trip_id) WHERE p.status='succeeded'")
  perl -e "printf \"SUMMARY clients=%-2d  trips actually paid=%d  wall time=%.2fs  real payments/s=%.0f\n\n\", $C, $PAID, $T1-$T0, $PAID/($T1-$T0)"
done
echo "=== Deadlocks / rollbacks recorded by PostgreSQL"
psql -X -c "SELECT deadlocks, xact_rollback FROM pg_stat_database WHERE datname = 'swiftmove'"
} 2>&1 | tee "$OUT"
