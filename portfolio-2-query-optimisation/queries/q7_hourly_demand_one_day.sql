-- Q7 Capacity planning: trip requests per hour on one day (time-range scan).
SELECT date_trunc('hour', requested_at) AS hour, count(*) AS requests
FROM swiftmove.trip
WHERE requested_at >= timestamptz '2026-06-15 00:00+01'
  AND requested_at <  timestamptz '2026-06-16 00:00+01'
GROUP BY 1
ORDER BY 1
