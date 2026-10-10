-- Q2 Driver app: daily earnings for the last 30 days.
SELECT date_trunc('day', completed_at) AS day, count(*) AS trips, sum(fare_amount) AS gross_ngn
FROM swiftmove.trip
WHERE driver_id = 17 AND status = 'completed'
  AND completed_at >= timestamptz '2026-09-10 00:00+01'
GROUP BY 1
ORDER BY 1
