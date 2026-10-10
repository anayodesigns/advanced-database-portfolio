-- Hot-spot experiment: identical to pay_trip() except the platform wallet row is NOT locked or
-- updated per payment. The commission is still written to the ledger, and a settlement job
-- (settle_platform()) rolls the ledger into the platform balance periodically.
SET search_path = swiftmove;
CREATE OR REPLACE FUNCTION pay_trip_deferred_commission(p_trip_id BIGINT) RETURNS TEXT
LANGUAGE plpgsql SET search_path = swiftmove AS $$
DECLARE t RECORD; v_comm NUMERIC(12,2); v_payment BIGINT; v_rider_w BIGINT; v_driver_w BIGINT;
BEGIN
  SELECT tr.trip_id, tr.rider_id, tr.driver_id, tr.fare_amount, sc.commission_rate INTO t
    FROM trip tr JOIN service_category sc ON sc.category_code = tr.category_code
   WHERE tr.trip_id = p_trip_id AND tr.status = 'completed' FOR UPDATE OF tr;
  IF NOT FOUND THEN RAISE EXCEPTION 'trip % is not a completed trip', p_trip_id; END IF;
  IF EXISTS (SELECT 1 FROM payment WHERE trip_id = p_trip_id AND status = 'succeeded') THEN RETURN 'already_paid'; END IF;
  SELECT max(wallet_id) FILTER (WHERE rider_id = t.rider_id), max(wallet_id) FILTER (WHERE driver_id = t.driver_id)
    INTO v_rider_w, v_driver_w
    FROM (SELECT wallet_id, rider_id, driver_id FROM wallet WHERE rider_id = t.rider_id OR driver_id = t.driver_id
          ORDER BY wallet_id FOR UPDATE) w;
  v_comm := round(t.fare_amount * t.commission_rate, 2);
  INSERT INTO payment (trip_id, method, amount, status, settled_at) VALUES (p_trip_id, 'wallet', t.fare_amount, 'succeeded', now())
  RETURNING payment_id INTO v_payment;
  UPDATE wallet SET balance = balance - t.fare_amount, version = version + 1, updated_at = now() WHERE wallet_id = v_rider_w;
  UPDATE wallet SET balance = balance + (t.fare_amount - v_comm), version = version + 1, updated_at = now() WHERE wallet_id = v_driver_w;
  INSERT INTO wallet_ledger (wallet_id, payment_id, entry_type, amount) VALUES
    (v_rider_w, v_payment, 'trip_debit', -t.fare_amount),
    (v_driver_w, v_payment, 'trip_credit', t.fare_amount - v_comm),
    (1, v_payment, 'commission', v_comm);          -- platform wallet_id = 1, ledger only
  RETURN 'paid';
END $$;
CREATE OR REPLACE FUNCTION settle_platform() RETURNS NUMERIC LANGUAGE sql SET search_path = swiftmove AS $$
  UPDATE wallet SET balance = (SELECT sum(amount) FROM wallet_ledger WHERE wallet_id = 1), updated_at = now()
  WHERE owner_kind = 'platform' RETURNING balance;
$$;
