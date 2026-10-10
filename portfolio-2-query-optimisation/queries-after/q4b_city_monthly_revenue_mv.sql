-- Q4b Same dashboard, served from the materialized view (refreshed every 15 minutes).
SELECT city, month, trips, gross_ngn, commission_ngn
FROM swiftmove.mv_city_monthly_revenue
WHERE month >= timestamptz '2026-04-01 00:00+01'
ORDER BY city, month
