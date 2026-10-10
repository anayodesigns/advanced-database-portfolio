-- =====================================================================
-- Portfolio 3 setup: demo data and the wallet-payment function.
-- Run once after Portfolio 1/2:  psql -f portfolio-3-transactions-concurrency/setup.sql
-- =====================================================================
SET search_path = swiftmove;
SELECT setseed(0.3);

-- ---------- 1. Clean up a data-quality problem found while preparing these demos ----------
-- The seed generator assigned some drivers two active trips at once. Nothing in the schema
-- prevented it; demo 05 shows the race that causes this in production and the constraint that
-- stops it. Here we cancel the older duplicate so the constraint can be created.
WITH ranked AS (
  SELECT trip_id, row_number() OVER (PARTITION BY driver_id ORDER BY requested_at DESC) AS rn
  FROM trip WHERE status IN ('accepted', 'in_progress'))
UPDATE trip t SET status = 'cancelled', cancelled_at = greatest(coalesce(t.started_at, t.accepted_at), t.requested_at) + interval '1 minute'
FROM ranked r WHERE r.trip_id = t.trip_id AND r.rn > 1
RETURNING t.trip_id AS cancelled_duplicate_trip, t.driver_id;

-- ---------- 2. Payment function used by demo 01 and the pgbench stress test ----------
CREATE OR REPLACE FUNCTION pay_trip(p_trip_id BIGINT) RETURNS TEXT
LANGUAGE plpgsql SET search_path = swiftmove AS $$
DECLARE
  t           RECORD;
  v_comm      NUMERIC(12,2);
  v_payment   BIGINT;
  v_rider_w   BIGINT;
  v_driver_w  BIGINT;
  v_platform_w BIGINT;
BEGIN
  -- Lock the trip row first: two payment attempts for the same trip are serialised here.
  SELECT tr.trip_id, tr.rider_id, tr.driver_id, tr.fare_amount, sc.commission_rate
    INTO t
    FROM trip tr JOIN service_category sc ON sc.category_code = tr.category_code
   WHERE tr.trip_id = p_trip_id AND tr.status = 'completed'
     FOR UPDATE OF tr;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'trip % is not a completed trip', p_trip_id USING ERRCODE = 'P0002';
  END IF;

  -- Idempotency: a retried request must not charge twice.
  IF EXISTS (SELECT 1 FROM payment WHERE trip_id = p_trip_id AND status = 'succeeded') THEN
    RETURN 'already_paid';
  END IF;

  -- Lock all three wallets in ascending wallet_id order (deadlock prevention, see demo 06).
  SELECT max(wallet_id) FILTER (WHERE rider_id = t.rider_id),
         max(wallet_id) FILTER (WHERE driver_id = t.driver_id),
         max(wallet_id) FILTER (WHERE owner_kind = 'platform')
    INTO v_rider_w, v_driver_w, v_platform_w
    FROM (SELECT wallet_id, rider_id, driver_id, owner_kind FROM wallet
           WHERE rider_id = t.rider_id OR driver_id = t.driver_id OR owner_kind = 'platform'
           ORDER BY wallet_id FOR UPDATE) w;

  v_comm := round(t.fare_amount * t.commission_rate, 2);

  INSERT INTO payment (trip_id, method, amount, status, settled_at)
  VALUES (p_trip_id, 'wallet', t.fare_amount, 'succeeded', now())
  RETURNING payment_id INTO v_payment;

  -- If the rider cannot afford it, ck_wallet_balance raises here and the WHOLE
  -- transaction (payment row included) is rolled back.
  UPDATE wallet SET balance = balance - t.fare_amount, version = version + 1, updated_at = now() WHERE wallet_id = v_rider_w;
  UPDATE wallet SET balance = balance + (t.fare_amount - v_comm), version = version + 1, updated_at = now() WHERE wallet_id = v_driver_w;
  UPDATE wallet SET balance = balance + v_comm, version = version + 1, updated_at = now() WHERE wallet_id = v_platform_w;

  INSERT INTO wallet_ledger (wallet_id, payment_id, entry_type, amount) VALUES
    (v_rider_w,    v_payment, 'trip_debit',  -t.fare_amount),
    (v_driver_w,   v_payment, 'trip_credit', t.fare_amount - v_comm),
    (v_platform_w, v_payment, 'commission',  v_comm);
  RETURN 'paid';
END $$;

-- Top-up helper: balance and ledger change together, in one transaction.
CREATE OR REPLACE FUNCTION topup(p_rider_id BIGINT, p_amount NUMERIC) RETURNS NUMERIC
LANGUAGE sql SET search_path = swiftmove AS $$
  WITH w AS (UPDATE wallet SET balance = balance + p_amount, version = version + 1, updated_at = now()
             WHERE rider_id = p_rider_id RETURNING wallet_id, balance)
  , l AS (INSERT INTO wallet_ledger (wallet_id, entry_type, amount) SELECT wallet_id, 'topup', p_amount FROM w)
  SELECT balance FROM w;
$$;

-- ---------- 3. Demo riders and 20,000 unpaid trips for the stress test ----------
-- Riders 49951-50000 (Kano) get NGN 5,000,000 each; drivers are Kano ECONOMY drivers.
SELECT count(topup(r, 5000000)) AS riders_topped_up FROM generate_series(49951, 50000) r;

INSERT INTO trip (trip_type, rider_id, driver_id, vehicle_id, category_code, pickup_zone_id, dropoff_zone_id,
                  pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, status, requested_at, accepted_at, started_at,
                  completed_at, distance_km, duration_min, fare_amount)
SELECT 'ride', 49951 + (g % 50), d, d, 'ECONOMY', 501 + g % 10, 501 + (g * 7) % 10,
       12.0, 8.53, 12.01, 8.54, 'completed',
       now() - interval '2 hours', now() - interval '115 minutes', now() - interval '110 minutes', now() - interval '80 minutes',
       8.5, 30.0, 1500 + (g % 46) * 100
FROM generate_series(1, 20000) g
CROSS JOIN LATERAL (SELECT 4601 + 10 * ((g * 37) % 40) + (g % 6) AS d) dd;

-- One trip for demo 01 (commit) and one deliberately unaffordable trip for demo 02 (rollback).
CREATE TABLE IF NOT EXISTS demo_trip (name TEXT PRIMARY KEY, trip_id BIGINT NOT NULL);
TRUNCATE demo_trip;
INSERT INTO demo_trip
SELECT 'commit_demo', min(trip_id) FROM trip WHERE trip_id > 1000000 AND status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM payment p WHERE p.trip_id = trip.trip_id);
WITH r AS (SELECT w.balance FROM wallet w WHERE w.rider_id = 41001)
, ins AS (
  INSERT INTO trip (trip_type, rider_id, driver_id, vehicle_id, category_code, pickup_zone_id, dropoff_zone_id,
                    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, status, requested_at, accepted_at, started_at,
                    completed_at, distance_km, duration_min, fare_amount)
  SELECT 'delivery', 41001, 4110, 4110, 'VAN', 401, 410, 7.43, 3.91, 7.44, 3.95, 'completed',
         now() - interval '3 hours', now() - interval '170 minutes', now() - interval '165 minutes', now() - interval '60 minutes',
         31.0, 105.0, r.balance + 2500          -- costs NGN 2,500 more than the rider has
  FROM r RETURNING trip_id)
INSERT INTO demo_trip SELECT 'rollback_demo', trip_id FROM ins;

-- Stress-test pool: every unpaid demo trip.
CREATE TABLE IF NOT EXISTS stress_trip (n INT PRIMARY KEY, trip_id BIGINT NOT NULL);
TRUNCATE stress_trip;
INSERT INTO stress_trip SELECT row_number() OVER (ORDER BY trip_id), trip_id
FROM trip WHERE trip_id > 1000000 AND rider_id BETWEEN 49951 AND 50000
  AND trip_id <> (SELECT trip_id FROM demo_trip WHERE name = 'commit_demo');

ANALYZE trip; ANALYZE wallet;
SELECT * FROM demo_trip;
SELECT count(*) AS stress_trips FROM stress_trip;
