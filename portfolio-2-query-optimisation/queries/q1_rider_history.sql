-- Q1 Rider app: "My trips" screen – a heavy user's 20 most recent trips with zone names.
SELECT t.trip_id, t.requested_at, t.status, t.category_code,
       pz.name AS pickup, dz.name AS dropoff, t.fare_amount
FROM swiftmove.trip t
JOIN swiftmove.zone pz ON pz.zone_id = t.pickup_zone_id
JOIN swiftmove.zone dz ON dz.zone_id = t.dropoff_zone_id
WHERE t.rider_id = 25001
ORDER BY t.requested_at DESC
LIMIT 20
