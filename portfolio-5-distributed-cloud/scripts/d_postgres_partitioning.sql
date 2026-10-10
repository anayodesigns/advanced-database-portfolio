-- Part D — Horizontal partitioning in PostgreSQL: trips split by month (range partitioning).
-- Shows partition pruning (planning- and run-time) and O(1) archiving by detaching a partition.
SET search_path = swiftmove;
\timing off
DROP TABLE IF EXISTS trip_by_month CASCADE;
DROP TABLE IF EXISTS trip_archive_2025_10;

CREATE TABLE trip_by_month (LIKE trip INCLUDING DEFAULTS INCLUDING CONSTRAINTS) PARTITION BY RANGE (requested_at);
DO $$
DECLARE m date := date '2025-10-01';
BEGIN
  WHILE m <= date '2026-10-01' LOOP
    EXECUTE format('CREATE TABLE trip_by_month_%s PARTITION OF trip_by_month FOR VALUES FROM (%L) TO (%L)',
                   to_char(m, 'YYYY_MM'), m::timestamptz, (m + interval '1 month')::timestamptz);
    m := m + interval '1 month';
  END LOOP;
END $$;
CREATE TABLE trip_by_month_default PARTITION OF trip_by_month DEFAULT;
ALTER TABLE trip_by_month ADD PRIMARY KEY (trip_id, requested_at);    -- PK must include the partition key
CREATE INDEX ON trip_by_month (rider_id, requested_at DESC);          -- becomes one local index per partition

\echo '=== D1. Load 1,000,000 trips; rows per partition'
\timing on
INSERT INTO trip_by_month SELECT * FROM trip WHERE trip_id <= 1000000;
\timing off
ANALYZE trip_by_month;
SELECT tableoid::regclass AS partition, count(*) AS trips, pg_size_pretty(pg_relation_size(tableoid)) AS size
FROM trip_by_month GROUP BY tableoid ORDER BY 1;

\echo '=== D2. Planning-time pruning: one month of data -> only that partition is scanned'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM trip_by_month
WHERE requested_at >= '2026-06-01 00:00+01' AND requested_at < '2026-07-01 00:00+01';

\echo '=== D3. Run-time pruning: parameter value only known at execution (prepared statement, generic plan)'
SET plan_cache_mode = force_generic_plan;
PREPARE trips_since(timestamptz) AS SELECT count(*) FROM trip_by_month WHERE requested_at >= $1;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE trips_since('2026-09-15 00:00+01');
DEALLOCATE trips_since;
RESET plan_cache_mode;

\echo '=== D4. A query without the partition key must visit every partition (cf. scatter-gather in Part C)'
EXPLAIN (COSTS OFF) SELECT count(*) FROM trip_by_month WHERE rider_id = 25001;

\echo '=== D5. Archiving a month: DETACH (metadata only) vs DELETE (row by row)'
CREATE TABLE trip_delete_test AS SELECT * FROM trip_by_month_2025_10;
\timing on
DELETE FROM trip_delete_test;
ALTER TABLE trip_by_month DETACH PARTITION trip_by_month_2025_10;
\timing off
ALTER TABLE trip_by_month_2025_10 RENAME TO trip_archive_2025_10;
SELECT count(*) AS rows_now_in_archive_table FROM trip_archive_2025_10;
SELECT count(*) AS oct_2025_rows_left_in_partitioned_table FROM trip_by_month WHERE requested_at < '2025-11-01 00:00+01';
DROP TABLE trip_delete_test;
