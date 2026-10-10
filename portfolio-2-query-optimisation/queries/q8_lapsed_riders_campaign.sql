-- Q8 Marketing: Abuja riders with >= NGN 15,000 in their wallet who have not travelled in 60 days.
SELECT r.rider_id, r.full_name, w.balance
FROM swiftmove.rider r
JOIN swiftmove.wallet w ON w.rider_id = r.rider_id
WHERE r.home_city_id = 2 AND r.status = 'active' AND w.balance >= 15000
  AND NOT EXISTS (SELECT 1 FROM swiftmove.trip t
                  WHERE t.rider_id = r.rider_id
                    AND t.requested_at >= timestamptz '2026-08-11 00:00+01')
ORDER BY w.balance DESC
LIMIT 25
