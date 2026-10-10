#!/bin/bash
# Part A — PostgreSQL streaming replication: primary (5433) -> hot standby (5434).
# Shows: replication status, lag, read-only standby, async vs synchronous commit, crash + failover.
# At the end the original primary is restored as the main database so other portfolios keep working.
cd "$(dirname "$0")"; . ../../scripts/env.sh
OUT=../evidence/a-postgres-replication.txt; : > $OUT
P="psql -X -p 5433"; R="psql -X -p 5434"
log() { echo "$@" | tee -a $OUT; }
run() { echo "\$ $*" | tee -a $OUT; "$@" 2>&1 | tee -a $OUT; echo | tee -a $OUT; }
REPLICA=$VAR/pg/replica

log "=== A1. Build the standby with pg_basebackup (physical copy + replication slot + standby config)"
pg_ctl -D $REPLICA stop -m fast >/dev/null 2>&1; rm -rf $REPLICA
$P -d postgres -qc "SELECT pg_drop_replication_slot('replica1') FROM pg_replication_slots WHERE slot_name='replica1'" >/dev/null
T0=$(date +%s)
run pg_basebackup -h localhost -p 5433 -U postgres -D $REPLICA -R -X stream -C -S replica1 --progress
log "basebackup took $(( $(date +%s) - T0 )) s"
echo "primary_conninfo = 'host=localhost port=5433 user=postgres application_name=replica1'" >> $REPLICA/postgresql.auto.conf
run pg_ctl -D $REPLICA -o "-p 5434" -l $VAR/log/pg-replica.log -w start
sleep 2

log "=== A2. Replication status as seen from the primary and the standby"
run $P -c "SELECT application_name, state, sync_state, sent_lsn, replay_lsn, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes, replay_lag FROM pg_stat_replication"
run $R -c "SELECT pg_is_in_recovery() AS is_standby, pg_last_wal_replay_lsn() AS replayed_to, now() - pg_last_xact_replay_timestamp() AS time_since_last_replayed_txn"

log "=== A3. Write on the primary, read it on the standby; measure how long until it is visible"
$P -qc "CREATE TABLE IF NOT EXISTS swiftmove.replication_probe (id serial PRIMARY KEY, written_at timestamptz DEFAULT clock_timestamp(), note text)"
for i in 1 2 3 4 5; do
  ID=$($P -qAt -c "INSERT INTO swiftmove.replication_probe (note) VALUES ('probe $i') RETURNING id")
  N=0; START=$(perl -MTime::HiRes=time -e 'print time')
  until [ "$($R -At -c "SELECT count(*) FROM swiftmove.replication_probe WHERE id = $ID" 2>/dev/null)" = 1 ] || [ $N -ge 2000 ]; do N=$((N+1)); done
  perl -e "printf \"probe %d: visible on standby after %.1f ms (%d polls)\n\", $i, (\$ARGV[0]-$START)*1000, $N" "$(perl -MTime::HiRes=time -e 'print time')" | tee -a $OUT
done
echo | tee -a $OUT

log "=== A4. The standby is read-only (hot standby): reads work, writes are refused"
run $R -c "SELECT count(*) AS trips_on_standby FROM swiftmove.trip"
run $R -c "UPDATE swiftmove.wallet SET balance = balance + 1 WHERE wallet_id = 2"

log "=== A5. Read scaling: the analytics query (Portfolio 2 Q4b) served by the standby"
run $R -c "SELECT city, sum(trips) AS trips_6_months FROM swiftmove.mv_city_monthly_revenue WHERE month >= '2026-04-01' GROUP BY city ORDER BY 2 DESC"

log "=== A6. Asynchronous vs synchronous commit (pgbench, 4 clients, 10 s, wallet payments from Portfolio 3)"
$P -q -f ../../portfolio-3-transactions-concurrency/demos/reset_stress.sql
log "--- asynchronous (default): COMMIT returns once WAL is flushed on the primary"
pgbench -p 5433 -n -c 4 -j 4 -T 10 -f ../../portfolio-3-transactions-concurrency/demos/pay_trip.pgbench 2>&1 | grep -E "latency average|^tps" | tee -a $OUT
$P -qc "ALTER SYSTEM SET synchronous_standby_names = 'replica1'" -c "SELECT pg_reload_conf()" >/dev/null; sleep 1
run $P -c "SELECT application_name, sync_state FROM pg_stat_replication"
$P -q -f ../../portfolio-3-transactions-concurrency/demos/reset_stress.sql
log "--- synchronous: COMMIT also waits for the standby to confirm the WAL is flushed"
pgbench -p 5433 -n -c 4 -j 4 -T 10 -f ../../portfolio-3-transactions-concurrency/demos/pay_trip.pgbench 2>&1 | grep -E "latency average|^tps" | tee -a $OUT
$P -qc "ALTER SYSTEM SET synchronous_standby_names = ''" -c "SELECT pg_reload_conf()" >/dev/null
$P -q -f ../../portfolio-3-transactions-concurrency/demos/reset_stress.sql
echo | tee -a $OUT

log "=== A7. Lag under write load: bulk insert 2,000,000 GPS-ping rows on the primary, sample lag while it streams"
$P -qc "CREATE TABLE IF NOT EXISTS swiftmove.gps_ping_demo (driver_id int, ts timestamptz, lat float8, lng float8)"
( $P -qc "INSERT INTO swiftmove.gps_ping_demo SELECT g % 5000, now(), 6.4 + random()/10, 3.4 + random()/10 FROM generate_series(1, 2000000) g" ) &
for i in 1 2 3 4 5 6; do
  $P -At -c "SELECT format('t+%ss  lag_bytes=%s  write_lag=%s  replay_lag=%s', $i, coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),0), write_lag, replay_lag) FROM pg_stat_replication" | tee -a $OUT
  sleep 1
done
wait
sleep 2; $P -At -c "SELECT format('after load: lag_bytes=%s', pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) FROM pg_stat_replication" | tee -a $OUT
$P -qc "DROP TABLE swiftmove.gps_ping_demo"
echo | tee -a $OUT

log "=== A8. Failover: commit a payment, crash the primary, promote the standby"
TRIP=$($P -qAt -c "SELECT trip_id FROM swiftmove.stress_trip ORDER BY n LIMIT 1")
run $P -c "SELECT swiftmove.pay_trip($TRIP) AS committed_on_primary_before_crash"
sleep 1
run pg_ctl -D $VAR/pg/primary stop -m immediate
run $R -c "SELECT pg_is_in_recovery() AS still_standby"
T0=$(perl -MTime::HiRes=time -e 'print time')
run pg_ctl -D $REPLICA promote -w
perl -e "printf \"promotion took %.0f ms\n\", (\$ARGV[0]-$T0)*1000" "$(perl -MTime::HiRes=time -e 'print time')" | tee -a $OUT
run $R -c "SELECT pg_is_in_recovery() AS still_standby"
run $R -c "SELECT trip_id, status, amount FROM swiftmove.payment WHERE trip_id = $TRIP AND status = 'succeeded'"
log "--- the promoted server now accepts writes:"
run $R -c "INSERT INTO swiftmove.replication_probe (note) VALUES ('written after failover') RETURNING id, note"
run $R -c "SELECT count(*) AS wallets_not_matching_ledger FROM swiftmove.wallet w JOIN (SELECT wallet_id, sum(amount) s FROM swiftmove.wallet_ledger GROUP BY wallet_id) l USING (wallet_id) WHERE w.balance <> l.s"

log "=== A9. Clean-up: retire the promoted copy, restart the original primary (it still has every commit up to the crash)"
pg_ctl -D $REPLICA stop -m fast >/dev/null; rm -rf $REPLICA
pg_ctl -D $VAR/pg/primary -o "-p 5433" -l $VAR/log/pg-primary.log -w start >/dev/null
$P -d postgres -qc "SELECT pg_drop_replication_slot('replica1') FROM pg_replication_slots WHERE slot_name='replica1'" >/dev/null
run $P -c "SELECT pg_is_in_recovery() AS is_standby, (SELECT count(*) FROM swiftmove.payment WHERE trip_id = $TRIP AND status='succeeded') AS crash_test_payment_present"
$P -q -f ../../portfolio-3-transactions-concurrency/demos/reset_stress.sql
