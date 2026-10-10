-- Portfolio 2 optimisations. Each object targets one query; see README.md for the reasoning.
SET search_path = swiftmove;
\timing on

-- Q1 + Q8: equality on rider_id, then ordered by time. The DESC order lets "latest 20" stop after 20 index entries.
CREATE INDEX ix_trip_rider_requested ON trip (rider_id, requested_at DESC);

-- Q2: partial (only completed trips) + covering (INCLUDE fare_amount) => index-only scan, no heap visits.
CREATE INDEX ix_trip_driver_completed ON trip (driver_id, completed_at) INCLUDE (fare_amount)
  WHERE status = 'completed';

-- Q3: the dispatcher only ever looks at open requests (~300 of 1M rows), so a partial index stays tiny.
CREATE INDEX ix_trip_open_requests ON trip (pickup_zone_id, requested_at) WHERE status = 'requested';

-- Q5: recent rider->driver ratings; INCLUDE the columns the query needs from rating.
CREATE INDEX ix_rating_recent_r2d ON rating (created_at) INCLUDE (trip_id, score)
  WHERE direction = 'rider_to_driver';

-- Q6: the UNIQUE(email) index cannot serve lower(email) = ...; an expression index can.
CREATE INDEX ix_rider_email_lower ON rider (lower(email));

-- Q7: requested_at grows with trip_id (append order), so a BRIN index works and is tiny.
CREATE INDEX ix_trip_requested_brin ON trip USING brin (requested_at) WITH (pages_per_range = 32);

-- General FK index (joins from driver to trip); not needed by Q2 because of the partial index above.
CREATE INDEX ix_trip_driver ON trip (driver_id);

-- Q4: a 6-month aggregate over ~450k rows cannot be made cheap by an index; pre-aggregate it instead.
CREATE MATERIALIZED VIEW mv_city_monthly_revenue AS
SELECT c.name AS city, date_trunc('month', t.completed_at) AS month,
       count(*) AS trips, sum(t.fare_amount) AS gross_ngn,
       round(sum(t.fare_amount * sc.commission_rate), 2) AS commission_ngn
FROM trip t
JOIN zone z ON z.zone_id = t.pickup_zone_id
JOIN city c ON c.city_id = z.city_id
JOIN service_category sc ON sc.category_code = t.category_code
WHERE t.status = 'completed'
GROUP BY c.name, date_trunc('month', t.completed_at);
CREATE UNIQUE INDEX ux_mv_city_month ON mv_city_monthly_revenue (city, month);  -- allows REFRESH ... CONCURRENTLY

-- Keep the visibility map current (index-only scans) and statistics fresh.
VACUUM ANALYZE trip;
VACUUM ANALYZE rating;
ANALYZE rider;
\timing off

-- Index sizes (cost of the optimisation)
SELECT indexrelname AS index, relname AS table_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE schemaname = 'swiftmove' AND relname IN ('trip', 'rating', 'rider')
ORDER BY pg_relation_size(indexrelid) DESC;
