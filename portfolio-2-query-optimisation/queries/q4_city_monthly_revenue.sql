-- Q4 Finance dashboard: revenue and commission per city per month (last 6 months).
SELECT c.name AS city, date_trunc('month', t.completed_at) AS month,
       count(*) AS trips, sum(t.fare_amount) AS gross_ngn,
       round(sum(t.fare_amount * sc.commission_rate), 2) AS commission_ngn
FROM swiftmove.trip t
JOIN swiftmove.zone z ON z.zone_id = t.pickup_zone_id
JOIN swiftmove.city c ON c.city_id = z.city_id
JOIN swiftmove.service_category sc ON sc.category_code = t.category_code
WHERE t.status = 'completed' AND t.completed_at >= timestamptz '2026-04-01 00:00+01'
GROUP BY c.name, date_trunc('month', t.completed_at)
ORDER BY c.name, month
