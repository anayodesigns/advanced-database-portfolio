-- Q5 Operations: top 10 Lagos drivers by average rating in the last 30 days (min. 20 ratings).
SELECT d.driver_id, d.full_name, count(*) AS ratings, round(avg(r.score), 2) AS avg_score
FROM swiftmove.rating r
JOIN swiftmove.trip t   ON t.trip_id = r.trip_id
JOIN swiftmove.driver d ON d.driver_id = t.driver_id
WHERE r.direction = 'rider_to_driver'
  AND r.created_at >= timestamptz '2026-09-10 00:00+01'
  AND d.city_id = 1
GROUP BY d.driver_id, d.full_name
HAVING count(*) >= 20
ORDER BY avg_score DESC, ratings DESC
LIMIT 10
