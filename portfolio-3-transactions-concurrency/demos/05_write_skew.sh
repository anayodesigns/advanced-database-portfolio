#!/bin/bash
# Demo 05 — Write skew: rule "a driver serves at most ONE active trip". Two dispatchers
# assign the same idle driver (4999, Kano BIKE) to two different requested trips at once.
# Each checks the rule first, then writes a DIFFERENT row, so row locks never conflict.
cd "$(dirname "$0")"; . ./lib.sh
OUT="$EVID/05-write-skew.txt"; : > "$OUT"
D=4999
psql -X -q -c "DROP INDEX IF EXISTS swiftmove.uq_trip_one_active_per_driver"
read T1 T2 < <(psql -X -At -F' ' -c "
  WITH ins AS (INSERT INTO swiftmove.trip (rider_id, category_code, pickup_zone_id, dropoff_zone_id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng)
               SELECT r, 'BIKE', 505, 506, 11.98, 8.52, 11.99, 8.51 FROM (VALUES (49990), (49991)) v(r) RETURNING trip_id)
  SELECT min(trip_id), max(trip_id) FROM ins")
echo "Driver $D, requested trips $T1 and $T2" | tee -a "$OUT"
reset_trips() { psql -X -q -c "UPDATE swiftmove.trip SET status='requested', driver_id=NULL, vehicle_id=NULL, accepted_at=NULL WHERE trip_id IN ($T1,$T2)"; }
check() { psql -X -At -c "SELECT 'RESULT  active trips for driver $D = ' || count(*) || CASE WHEN count(*) > 1 THEN '   <-- RULE VIOLATED' ELSE '   (rule holds)' END FROM swiftmove.trip WHERE driver_id = $D AND status IN ('accepted','in_progress')" | tee -a "$OUT"; echo | tee -a "$OUT"; }
make_sql() {  # make_sql LEVEL TRIP
cat <<SQL
BEGIN ISOLATION LEVEL $1;
-- check the rule
SELECT count(*) AS active_trips_for_driver FROM swiftmove.trip WHERE driver_id = $D AND status IN ('accepted', 'in_progress');
SELECT pg_sleep(1.5) \g /dev/null
-- rule looked fine, so assign the driver
UPDATE swiftmove.trip SET driver_id = $D, vehicle_id = $D, status = 'accepted', accepted_at = now() WHERE trip_id = $2;
COMMIT;
SQL
}
for LEVEL in "READ COMMITTED" "REPEATABLE READ" "SERIALIZABLE"; do
  reset_trips
  make_sql "$LEVEL" $T1 > "$TMP/a.sql"; make_sql "$LEVEL" $T2 > "$TMP/b.sql"
  session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.5
  timeline "Both dispatchers at $LEVEL" "$OUT"; check
done

# Structural fix: let the database enforce the rule with a partial unique index.
reset_trips
psql -X -c "CREATE UNIQUE INDEX uq_trip_one_active_per_driver ON swiftmove.trip (driver_id) WHERE status IN ('accepted', 'in_progress')" | tee -a "$OUT"
make_sql "READ COMMITTED" $T1 > "$TMP/a.sql"; make_sql "READ COMMITTED" $T2 > "$TMP/b.sql"
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.5
timeline "READ COMMITTED + partial unique index uq_trip_one_active_per_driver" "$OUT"; check
reset_trips
