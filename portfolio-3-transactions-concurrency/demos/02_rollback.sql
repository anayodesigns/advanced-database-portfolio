-- Demo 02 — ROLLBACK in three forms.
SET search_path = swiftmove;
\set ON_ERROR_STOP 0
\set trip `psql -X -At -c "SELECT trip_id FROM swiftmove.demo_trip WHERE name='rollback_demo'"`

\echo '=== 2a. Automatic rollback: the rider cannot afford the trip (fare = balance + 2,500)'
SELECT t.trip_id, t.rider_id, t.fare_amount, w.balance AS rider_balance FROM trip t JOIN wallet w ON w.rider_id = t.rider_id WHERE t.trip_id = :trip;
SELECT (SELECT count(*) FROM payment) AS payments_before, (SELECT count(*) FROM wallet_ledger) AS ledger_rows_before;
BEGIN;
SELECT pay_trip(:trip);
-- The CHECK constraint fired inside pay_trip; the transaction is now aborted:
SELECT 1;
ROLLBACK;
SELECT (SELECT count(*) FROM payment) AS payments_after, (SELECT count(*) FROM wallet_ledger) AS ledger_rows_after,
       (SELECT balance FROM wallet WHERE rider_id = (SELECT rider_id FROM trip WHERE trip_id = :trip)) AS rider_balance_after;
\echo '    -> The payment row inserted before the failing UPDATE was rolled back too (atomicity).'

\echo '=== 2b. Explicit ROLLBACK: a support agent marks the wrong trip's payment as refunded, notices, and undoes it'
BEGIN;
UPDATE payment SET status = 'refunded' WHERE trip_id = 100 AND status = 'succeeded' RETURNING payment_id, trip_id, status;
SELECT status FROM payment WHERE trip_id = 100 ORDER BY payment_id;
ROLLBACK;
SELECT status AS status_after_rollback FROM payment WHERE trip_id = 100 ORDER BY payment_id;

\echo '=== 2c. SAVEPOINT: partial rollback. Close out a trip; the optional loyalty bonus fails, the rest commits.'
BEGIN;
UPDATE trip SET status = 'completed', completed_at = now(), started_at = coalesce(started_at, now() - interval '20 minutes'),
       accepted_at = coalesce(accepted_at, now() - interval '25 minutes'), distance_km = 6.2, duration_min = 20, fare_amount = 2210
 WHERE trip_id = (SELECT min(trip_id) FROM trip WHERE status = 'in_progress') RETURNING trip_id, status, fare_amount;
SAVEPOINT loyalty_bonus;
-- Bonus would give the rider a rating row for a trip direction that already exists -> PK violation
INSERT INTO rating (trip_id, direction, score) SELECT trip_id, 'rider_to_driver', 5 FROM rating WHERE direction = 'rider_to_driver' LIMIT 1;
ROLLBACK TO SAVEPOINT loyalty_bonus;
SELECT 'transaction still usable after ROLLBACK TO SAVEPOINT' AS note;
COMMIT;
SELECT trip_id, status, fare_amount FROM trip WHERE trip_id = (SELECT max(trip_id) FROM trip WHERE status = 'completed' AND trip_id < 1000001 AND completed_at > now() - interval '1 minute');
