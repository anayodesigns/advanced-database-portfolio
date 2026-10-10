-- Money and consistency invariants checked before and after the stress test.
SET search_path = swiftmove;
SELECT (SELECT sum(balance) FROM wallet)                                   AS total_money_in_all_wallets,
       (SELECT sum(amount) FROM wallet_ledger)                             AS total_of_ledger,
       (SELECT count(*) FROM wallet w JOIN (SELECT wallet_id, sum(amount) s FROM wallet_ledger GROUP BY wallet_id) l USING (wallet_id) WHERE w.balance <> l.s) AS wallets_not_matching_ledger,
       (SELECT count(*) FROM (SELECT trip_id FROM payment WHERE status = 'succeeded' GROUP BY trip_id HAVING count(*) > 1) d) AS trips_paid_twice,
       (SELECT count(*) FROM wallet WHERE owner_kind = 'rider' AND balance < 0) AS negative_rider_wallets,
       (SELECT count(*) FROM payment p JOIN stress_trip s USING (trip_id) WHERE p.status = 'succeeded') AS stress_trips_paid;
