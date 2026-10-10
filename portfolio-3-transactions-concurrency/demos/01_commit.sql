-- Demo 01 — COMMIT: paying a completed trip from the rider's wallet is ONE atomic unit:
-- payment row + 3 balance updates + 3 ledger rows. Either all happen or none.
SET search_path = swiftmove;
\set trip `psql -X -At -c "SELECT trip_id FROM swiftmove.demo_trip WHERE name='commit_demo'"`
\echo '--- Before: trip, wallets involved, and whether a payment exists'
SELECT t.trip_id, t.rider_id, t.driver_id, t.fare_amount, sc.commission_rate FROM trip t JOIN service_category sc USING (category_code) WHERE trip_id = :trip;
SELECT wallet_id, owner_kind, coalesce(rider_id, driver_id) AS owner_id, balance FROM wallet
 WHERE rider_id = (SELECT rider_id FROM trip WHERE trip_id = :trip) OR driver_id = (SELECT driver_id FROM trip WHERE trip_id = :trip) OR owner_kind = 'platform' ORDER BY wallet_id;
SELECT count(*) AS payments_for_trip FROM payment WHERE trip_id = :trip;

\echo '--- Transaction'
BEGIN;
SELECT txid_current() AS transaction_id;
SELECT pay_trip(:trip);
\echo '--- Inside the transaction (uncommitted) – another session cannot see this yet:'
SELECT count(*) AS my_view_payments FROM payment WHERE trip_id = :trip;
\! psql -X -At -c "SELECT 'other session sees payments: ' || count(*) FROM swiftmove.payment WHERE trip_id = (SELECT trip_id FROM swiftmove.demo_trip WHERE name='commit_demo')"
COMMIT;

\echo '--- After COMMIT: balances moved, ledger written, visible to everyone'
\! psql -X -At -c "SELECT 'other session sees payments: ' || count(*) FROM swiftmove.payment WHERE trip_id = (SELECT trip_id FROM swiftmove.demo_trip WHERE name='commit_demo')"
SELECT wallet_id, owner_kind, coalesce(rider_id, driver_id) AS owner_id, balance FROM wallet
 WHERE rider_id = (SELECT rider_id FROM trip WHERE trip_id = :trip) OR driver_id = (SELECT driver_id FROM trip WHERE trip_id = :trip) OR owner_kind = 'platform' ORDER BY wallet_id;
SELECT l.wallet_id, l.entry_type, l.amount FROM wallet_ledger l JOIN payment p USING (payment_id) WHERE p.trip_id = :trip ORDER BY l.entry_id;
SELECT sum(l.amount) AS ledger_sum_should_be_zero FROM wallet_ledger l JOIN payment p USING (payment_id) WHERE p.trip_id = :trip;
\echo '--- Retrying the same payment is safe (idempotent):'
SELECT pay_trip(:trip);
