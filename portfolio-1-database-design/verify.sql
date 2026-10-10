-- Portfolio 1: integrity checks on the loaded data. Every check should return 0 / true.
SET search_path = swiftmove;
\pset footer off

\echo '1. Ledger matches wallet balances (rows where they differ):'
SELECT count(*) AS mismatched_wallets
FROM wallet w LEFT JOIN (SELECT wallet_id, sum(amount) s FROM wallet_ledger GROUP BY wallet_id) l USING (wallet_id)
WHERE w.balance <> coalesce(l.s, 0);

\echo '2. Wallet payments conserve money (debit + credits per payment should sum to 0):'
SELECT count(*) AS unbalanced_payments
FROM (SELECT payment_id, sum(amount) s FROM wallet_ledger WHERE entry_type IN ('trip_debit','trip_credit','commission') AND payment_id IS NOT NULL
      GROUP BY payment_id HAVING count(*) = 3) x
WHERE s <> 0;

\echo '3. Trips whose driver works in a different city from the pickup zone:'
SELECT count(*) AS cross_city_trips
FROM trip t JOIN driver d USING (driver_id) JOIN zone z ON z.zone_id = t.pickup_zone_id
WHERE d.city_id <> z.city_id;

\echo '4. Trips served by a vehicle in the wrong category:'
SELECT count(*) AS wrong_category FROM trip t JOIN vehicle v USING (vehicle_id) WHERE v.category_code <> t.category_code;

\echo '5. Every completed trip has exactly one successful payment:'
SELECT count(*) AS completed_without_payment
FROM trip t WHERE t.status = 'completed'
AND NOT EXISTS (SELECT 1 FROM payment p WHERE p.trip_id = t.trip_id AND p.status = 'succeeded');

\echo '6. Constraint test: a rider wallet cannot go negative (expect an error):'
\set ON_ERROR_STOP 0
UPDATE wallet SET balance = -1 WHERE wallet_id = 2;
\echo '7. Constraint test: a completed trip needs a fare (expect an error):'
UPDATE trip SET status = 'completed', fare_amount = NULL WHERE trip_id = (SELECT min(trip_id) FROM trip WHERE status = 'requested');
\echo '8. Constraint test: invalid phone format (expect an error):'
INSERT INTO rider (full_name, email, phone, home_city_id) VALUES ('Test User', 'test@x.example', '08012345678', 1);

\echo '--- Data profile ---'
SELECT status, count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct FROM trip GROUP BY status ORDER BY 2 DESC;
SELECT c.name AS city, count(*) AS trips, round(avg(t.fare_amount)) AS avg_fare_ngn
FROM trip t JOIN zone z ON z.zone_id = t.pickup_zone_id JOIN city c USING (city_id)
GROUP BY c.name ORDER BY trips DESC;
SELECT pg_size_pretty(pg_database_size('swiftmove')) AS database_size;
