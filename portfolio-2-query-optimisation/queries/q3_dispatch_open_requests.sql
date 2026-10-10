-- Q3 Dispatch/matching service (runs every few seconds): open requests in one zone, oldest first.
SELECT trip_id, rider_id, category_code, requested_at, pickup_lat, pickup_lng
FROM swiftmove.trip
WHERE status = 'requested' AND pickup_zone_id = 105
ORDER BY requested_at
