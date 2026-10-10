#!/bin/bash
# Extra experiments referenced in README.md section 4. Output: results/experiments.txt
cd "$(dirname "$0")"; . ../scripts/env.sh
Q4=$(grep -v '^--' queries/q4_city_monthly_revenue.sql)
Q5=$(grep -v '^--' queries/q5_top_rated_drivers.sql)
Q5B=$(grep -v '^--' queries-after/q5b_top_rated_drivers_window.sql)
{
echo "### E1. Q4 with work_mem = 4MB (default) vs 64MB — does the sort spill go away?"
for wm in 4MB 64MB; do echo "--- work_mem=$wm"; psql -X -At -c "SET work_mem='$wm'; EXPLAIN (ANALYZE, BUFFERS) $Q4" | grep -E "Aggregate|Sort Method|Execution"; done
echo; echo "### E2. Q5 forcing a nested-loop join (hash and merge joins disabled) — was the planner right to hash-join?"
psql -X -At -c "SET enable_hashjoin=off; SET enable_mergejoin=off; EXPLAIN (ANALYZE) $Q5" | grep -E "Nested Loop|Index|Execution"
echo; echo "### E3. Q5 vs Q5b (time-window predicate lets BRIN prune trip)"
for v in Q5 Q5B; do echo "--- $v"; psql -X -At -c "EXPLAIN (ANALYZE) ${!v}" | grep -E "Scan on trip|Bitmap Index Scan|Execution"; done
echo; echo "### E4. BRIN vs B-tree on trip.requested_at — size and speed for Q7"
psql -X -q -c "CREATE INDEX IF NOT EXISTS ix_trip_requested_btree ON swiftmove.trip (requested_at)"
psql -X -c "SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) FROM pg_stat_user_indexes WHERE indexrelname IN ('ix_trip_requested_brin','ix_trip_requested_btree')"
Q7=$(grep -v '^--' queries/q7_hourly_demand_one_day.sql)
echo "--- with both indexes the planner picks:"; psql -X -At -c "EXPLAIN (ANALYZE) $Q7" | grep -E "Index|Execution"
psql -X -q -c "DROP INDEX swiftmove.ix_trip_requested_btree"
echo "--- BRIN only:"; psql -X -At -c "EXPLAIN (ANALYZE) $Q7" | grep -E "Index|Rows Removed|Execution"
echo; echo "### E5. Correlation statistic that makes BRIN viable (1.0 = physical order matches column order)"
psql -X -c "SELECT attname, round(correlation::numeric, 4) AS correlation FROM pg_stats WHERE schemaname='swiftmove' AND tablename='trip' AND attname IN ('trip_id','requested_at','rider_id','driver_id')"
echo; echo "### E6. Materialized view refresh cost (paid every 15 min instead of on every dashboard load)"
psql -X -c "\timing on" -c "REFRESH MATERIALIZED VIEW CONCURRENTLY swiftmove.mv_city_monthly_revenue"
} > results/experiments.txt 2>&1
cat results/experiments.txt
{
echo; echo "### E7. Q5 with random_page_cost = 1.1 (SSD) instead of the default 4.0 — does the planner now pick the nested loop itself?"
for rpc in 4 1.1; do echo "--- random_page_cost=$rpc"; psql -X -At -c "SET random_page_cost=$rpc; EXPLAIN (ANALYZE) $Q5" | grep -E "Nested Loop|Hash Join|Seq Scan on trip|Execution" | head -4; done
} >> results/experiments.txt 2>&1
tail -12 results/experiments.txt
