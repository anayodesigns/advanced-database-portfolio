-- Undo all stress-test payments (payments + ledger rows) and rebuild the affected balances from the ledger.
SET search_path = swiftmove;
BEGIN;
CREATE TEMP TABLE sp ON COMMIT DROP AS SELECT payment_id FROM payment p JOIN stress_trip s USING (trip_id);
DELETE FROM wallet_ledger WHERE payment_id IN (SELECT payment_id FROM sp);
DELETE FROM payment WHERE payment_id IN (SELECT payment_id FROM sp);
UPDATE wallet w SET balance = coalesce((SELECT sum(amount) FROM wallet_ledger l WHERE l.wallet_id = w.wallet_id), 0)
 WHERE w.owner_kind = 'platform' OR w.rider_id BETWEEN 49951 AND 50000 OR w.driver_id BETWEEN 4601 AND 5000;
COMMIT;
