-- Q5b Q5 rewritten: ratings are only accepted within 24 h of the trip (business rule), so the trip side can be limited to the same window (+1 day); the BRIN index then skips ~91% of trip.
SELECT d.driver_id, d.full_name, count(*) AS ratings, round(avg(r.score), 2) AS avg_score
FROM swiftmove.rating r
JOIN swiftmove.trip t   ON t.trip_id = r.trip_id
JOIN swiftmove.driver d ON d.driver_id = t.driver_id
WHERE r.direction = 'rider_to_driver'
  AND r.created_at >= timestamptz '2026-09-10 00:00+01'
  AND t.requested_at >= timestamptz '2026-09-09 00:00+01'
  AND d.city_id = 1
GROUP BY d.driver_id, d.full_name
HAVING count(*) >= 20
ORDER BY avg_score DESC, ratings DESC
LIMIT 10
