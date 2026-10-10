#!/bin/bash
# Demo 08 — Is the single platform-wallet row the bottleneck? Run the same 16-client workload with
# commission credited per payment (pay_trip) vs deferred to a settlement job.
cd "$(dirname "$0")"; . ./lib.sh
OUT="$EVID/08-hotspot.txt"; : > "$OUT"
psql -X -q -f hotspot_fix.sql
{
for V in pay_trip pay_trip_deferred; do
  psql -X -q -f reset_stress.sql
  echo "=== $V: 16 clients x 1250 transactions"
  T0=$(perl -MTime::HiRes=time -e 'print time')
  pgbench -n -c 16 -j 4 -t 1250 -f $V.pgbench 2>&1 | grep -E "failed|latency average|^tps"
  T1=$(perl -MTime::HiRes=time -e 'print time')
  [ $V = pay_trip_deferred ] && { echo "--- settlement job:"; psql -X -At -c "SELECT 'platform balance after settle_platform(): ' || swiftmove.settle_platform()"; }
  PAID=$(psql -X -At -c "SELECT count(*) FROM swiftmove.payment p JOIN swiftmove.stress_trip s USING (trip_id) WHERE p.status='succeeded'")
  perl -e "printf \"SUMMARY %-18s paid=%d  wall=%.2fs  real payments/s=%.0f\n\", '$V', $PAID, $T1-$T0, $PAID/($T1-$T0)"
  echo "--- invariants:"; psql -X -q -f invariants.sql; echo
done
} 2>&1 | tee "$OUT"
