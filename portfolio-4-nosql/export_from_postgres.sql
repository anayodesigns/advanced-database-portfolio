-- Export SwiftMove data from PostgreSQL as one JSON document per line (NDJSON) for MongoDB.
-- Trips: every trip requested since 1 Sep 2026 (~110k), denormalised into self-contained documents.
-- Note GeoJSON order is [longitude, latitude].
\pset tuples_only on
\pset format unaligned
\o data/trips.ndjson
SELECT json_strip_nulls(json_build_object(
  '_id', t.trip_id,
  'type', t.trip_type,
  'status', t.status,
  'category', t.category_code,
  'city', c.name,
  'requested_at', t.requested_at,
  'rider', json_build_object('rider_id', r.rider_id, 'name', r.full_name, 'phone', r.phone),
  'driver', CASE WHEN d.driver_id IS NOT NULL THEN json_build_object(
      'driver_id', d.driver_id, 'name', d.full_name,
      'vehicle', json_build_object('plate', v.plate_no, 'make', v.make, 'model', v.model)) END,
  'pickup',  json_build_object('zone', pz.name, 'location', json_build_object('type', 'Point', 'coordinates', json_build_array(t.pickup_lng, t.pickup_lat))),
  'dropoff', json_build_object('zone', dz.name, 'location', json_build_object('type', 'Point', 'coordinates', json_build_array(t.dropoff_lng, t.dropoff_lat))),
  'status_history', (SELECT json_agg(json_build_object('status', e.status, 'at', e.changed_at) ORDER BY e.seq)
                     FROM swiftmove.trip_status_event e WHERE e.trip_id = t.trip_id),
  'fare', CASE WHEN t.fare_amount IS NOT NULL THEN json_build_object(
      'amount', t.fare_amount, 'currency', 'NGN', 'distance_km', t.distance_km, 'duration_min', t.duration_min,
      'commission', round(t.fare_amount * sc.commission_rate, 2)) END,
  'payment', (SELECT json_build_object('method', p.method, 'status', p.status, 'settled_at', p.settled_at)
              FROM swiftmove.payment p WHERE p.trip_id = t.trip_id AND p.status = 'succeeded'),
  'ratings', (SELECT json_object_agg(rt.direction, json_strip_nulls(json_build_object('score', rt.score, 'comment', rt.comment)))
              FROM swiftmove.rating rt WHERE rt.trip_id = t.trip_id),
  'parcel', (SELECT json_build_object('recipient', pa.recipient_name, 'recipient_phone', pa.recipient_phone,
                                      'size', pa.size_class, 'declared_value', pa.declared_value)
             FROM swiftmove.parcel pa WHERE pa.trip_id = t.trip_id)
))
FROM swiftmove.trip t
JOIN swiftmove.rider r ON r.rider_id = t.rider_id
LEFT JOIN swiftmove.driver d ON d.driver_id = t.driver_id
LEFT JOIN swiftmove.vehicle v ON v.vehicle_id = t.vehicle_id
JOIN swiftmove.zone pz ON pz.zone_id = t.pickup_zone_id
JOIN swiftmove.zone dz ON dz.zone_id = t.dropoff_zone_id
JOIN swiftmove.city c ON c.city_id = pz.city_id
JOIN swiftmove.service_category sc ON sc.category_code = t.category_code
WHERE t.requested_at >= timestamptz '2026-09-01 00:00+01' AND t.trip_id <= 1000000
ORDER BY t.trip_id;

-- Drivers with their vehicle and city (live location is generated in Mongo).
\o data/drivers.ndjson
SELECT json_build_object('_id', d.driver_id, 'name', d.full_name, 'city', c.name, 'status', d.status,
       'vehicle', json_build_object('plate', v.plate_no, 'category', v.category_code, 'make', v.make, 'model', v.model, 'year', v.model_year),
       'zones', (SELECT json_agg(json_build_object('zone', z.name, 'lng', z.centre_lng, 'lat', z.centre_lat)) FROM swiftmove.zone z WHERE z.city_id = c.city_id))
FROM swiftmove.driver d JOIN swiftmove.city c USING (city_id)
JOIN swiftmove.vehicle v ON v.driver_id = d.driver_id AND v.is_active
ORDER BY d.driver_id;

-- Riders (id, name, city) for the referral graph.
\o data/riders.ndjson
SELECT json_build_object('_id', r.rider_id, 'name', r.full_name, 'city', c.name)
FROM swiftmove.rider r JOIN swiftmove.city c ON c.city_id = r.home_city_id ORDER BY r.rider_id;
\o
