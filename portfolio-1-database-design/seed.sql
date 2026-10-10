-- =====================================================================
-- SwiftMove synthetic data (deterministic: setseed) – used by Portfolios 1-3
-- ~1M trips over 12 months across 5 Nigerian cities.
-- Run after schema.sql:  psql -f schema.sql -f seed.sql
-- =====================================================================
SET search_path = swiftmove;
SET max_parallel_workers_per_gather = 0;   -- keep random() sequence deterministic
SELECT setseed(0.42);

-- ---------- Cities and zones (real neighbourhoods, approximate centres) ----------
INSERT INTO city (city_id, name, state) VALUES
 (1, 'Lagos', 'Lagos'), (2, 'Abuja', 'FCT'), (3, 'Port Harcourt', 'Rivers'),
 (4, 'Ibadan', 'Oyo'), (5, 'Kano', 'Kano');

INSERT INTO zone (zone_id, city_id, name, centre_lat, centre_lng) VALUES
 (101,1,'Lekki Phase 1',6.4478,3.4723),(102,1,'Victoria Island',6.4281,3.4219),(103,1,'Ikoyi',6.4520,3.4350),
 (104,1,'Ikeja GRA',6.5833,3.3500),(105,1,'Yaba',6.5095,3.3711),(106,1,'Surulere',6.5000,3.3500),
 (107,1,'Ajah',6.4698,3.5852),(108,1,'Maryland',6.5730,3.3670),(109,1,'Gbagada',6.5550,3.3890),
 (110,1,'Festac',6.4660,3.2830),(111,1,'Apapa',6.4489,3.3590),(112,1,'Ikorodu',6.6194,3.5105),
 (113,1,'Oshodi',6.5550,3.3430),(114,1,'Magodo',6.6170,3.3830),(115,1,'Ogba',6.6290,3.3410),
 (116,1,'Egbeda',6.5910,3.2900),(117,1,'Ojota',6.5870,3.3800),(118,1,'Lagos Island',6.4550,3.3940),
 (119,1,'Sangotedo',6.4700,3.6300),(120,1,'Ilupeju',6.5530,3.3570),
 (201,2,'Wuse 2',9.0800,7.4700),(202,2,'Maitama',9.0880,7.4980),(203,2,'Garki',9.0280,7.4850),
 (204,2,'Asokoro',9.0440,7.5240),(205,2,'Gwarinpa',9.1080,7.4070),(206,2,'Jabi',9.0700,7.4300),
 (207,2,'Utako',9.0680,7.4400),(208,2,'Kubwa',9.1550,7.3220),(209,2,'Lugbe',8.9800,7.3700),(210,2,'Life Camp',9.0790,7.4130),
 (301,3,'GRA Phase 2',4.8150,7.0000),(302,3,'Trans Amadi',4.8100,7.0300),(303,3,'Rumuola',4.8350,7.0050),
 (304,3,'D-Line',4.7980,7.0050),(305,3,'Ada George',4.8400,6.9750),(306,3,'Rumuokoro',4.8700,6.9950),
 (307,3,'Woji',4.8300,7.0550),(308,3,'Old GRA',4.7800,7.0050),(309,3,'Eliozu',4.8650,7.0300),(310,3,'Choba',4.8930,6.9100),
 (401,4,'Bodija',7.4300,3.9100),(402,4,'Ring Road',7.3700,3.8800),(403,4,'Dugbe',7.3870,3.8790),
 (404,4,'Challenge',7.3500,3.8800),(405,4,'UI',7.4440,3.8990),(406,4,'Mokola',7.4040,3.8880),
 (407,4,'Jericho',7.3990,3.8640),(408,4,'Oluyole',7.3600,3.8600),(409,4,'Agodi',7.4020,3.9180),(410,4,'Akobo',7.4400,3.9500),
 (501,5,'Nassarawa GRA',12.0000,8.5300),(502,5,'Sabon Gari',12.0130,8.5300),(503,5,'Bompai',12.0100,8.5600),
 (504,5,'Tarauni',11.9700,8.5500),(505,5,'Gyadi-Gyadi',11.9800,8.5200),(506,5,'Kano Municipal',11.9960,8.5130),
 (507,5,'Hotoro',12.0200,8.5800),(508,5,'Sharada',11.9700,8.5000),(509,5,'Zoo Road',11.9850,8.5350),(510,5,'Fagge',12.0100,8.5150);

INSERT INTO service_category VALUES
 ('ECONOMY','Standard 4-seat car',4, 500.00,180.00,25.00,1200.00,0.200),
 ('COMFORT','Newer car, top-rated drivers',4, 800.00,260.00,35.00,2000.00,0.220),
 ('BIKE',   'Motorbike rides and small parcels',1, 250.00,110.00,15.00, 600.00,0.150),
 ('VAN',    'Mini-van for large parcels',0, 1500.00,320.00,40.00,3500.00,0.180);

-- Helper ranges: which rider / driver / zone ids belong to each city.
CREATE TEMP TABLE city_range (city_id SMALLINT PRIMARY KEY, weight NUMERIC, cum NUMERIC,
  r_lo INT, r_n INT, d_lo INT, d_n INT, z_lo INT, z_n INT);
INSERT INTO city_range VALUES
 (1,0.50,0.50,     1,25000,    1,2500,101,20),
 (2,0.20,0.70, 25001,10000, 2501,1000,201,10),
 (3,0.12,0.82, 35001, 6000, 3501, 600,301,10),
 (4,0.10,0.92, 41001, 5000, 4101, 500,401,10),
 (5,0.08,1.00, 46001, 4000, 4601, 400,501,10);

CREATE TEMP TABLE first_names AS SELECT unnest(ARRAY['Adaeze','Chinedu','Ngozi','Emeka','Funmilayo','Tunde','Aisha','Ibrahim','Zainab','Musa',
 'Kemi','Segun','Bola','Obinna','Chioma','Uche','Halima','Sani','Yetunde','Femi','Ifeoma','Kelechi','Amina','Bashir','Damilola',
 'Tobi','Nkechi','Ikenna','Fatima','Abubakar','Folake','Olumide','Ebuka','Amarachi','Hauwa','Yusuf','Temitope','Seun','Ada','Kunle']) AS n;
CREATE TEMP TABLE last_names AS SELECT unnest(ARRAY['Okafor','Adeyemi','Bello','Okonkwo','Abdullahi','Eze','Ogunleye','Mohammed','Nwosu','Balogun',
 'Ibrahim','Afolabi','Chukwu','Danjuma','Olawale','Nnamdi','Usman','Adebayo','Obi','Lawal','Okeke','Suleiman','Ojo','Umeh','Aliyu',
 'Akinola','Onyeka','Garba','Fashola','Ezeh']) AS n;
CREATE TEMP TABLE fn AS SELECT row_number() OVER () AS i, n FROM first_names;
CREATE TEMP TABLE ln AS SELECT row_number() OVER () AS i, n FROM last_names;

-- ---------- Riders (50,000) ----------
INSERT INTO rider (rider_id, full_name, email, phone, home_city_id, status, created_at) OVERRIDING SYSTEM VALUE
SELECT g, f.n || ' ' || l.n,
       lower(f.n || '.' || l.n || g) || '@mail.example',
       '+23480' || lpad(g::text, 8, '0'),
       cr.city_id,
       CASE WHEN g % 211 = 0 THEN 'suspended' WHEN g % 503 = 0 THEN 'closed' ELSE 'active' END,
       timestamptz '2024-01-01 08:00+01' + (g::numeric / 50000) * interval '640 days'
FROM generate_series(1, 50000) g
JOIN city_range cr ON g BETWEEN cr.r_lo AND cr.r_lo + cr.r_n - 1
JOIN fn f ON f.i = 1 + (g * 7) % 40
JOIN ln l ON l.i = 1 + (g * 13) % 30;

-- ---------- Drivers (5,000) and their vehicles ----------
-- Vehicle category is fixed by (driver_id - 1) % 10: 0-5 ECONOMY, 6-7 COMFORT, 8 BIKE, 9 VAN.
INSERT INTO driver (driver_id, full_name, email, phone, licence_no, city_id, status, joined_at) OVERRIDING SYSTEM VALUE
SELECT g, f.n || ' ' || l.n,
       lower('drv.' || f.n || '.' || l.n || g) || '@swiftmove.example',
       '+23490' || lpad(g::text, 8, '0'),
       (ARRAY['LAG','ABJ','PHC','IBD','KAN'])[cr.city_id] || lpad(g::text, 7, '0'),
       cr.city_id,
       CASE WHEN g % 97 = 0 THEN 'suspended' ELSE 'approved' END,
       timestamptz '2023-06-01 09:00+01' + (g::numeric / 5000) * interval '480 days'
FROM generate_series(1, 5000) g
JOIN city_range cr ON g BETWEEN cr.d_lo AND cr.d_lo + cr.d_n - 1
JOIN fn f ON f.i = 1 + (g * 11) % 40
JOIN ln l ON l.i = 1 + (g * 17) % 30;

INSERT INTO vehicle (vehicle_id, driver_id, category_code, plate_no, make, model, model_year, is_active) OVERRIDING SYSTEM VALUE
SELECT d.driver_id, d.driver_id,
       CASE WHEN (d.driver_id - 1) % 10 < 6 THEN 'ECONOMY' WHEN (d.driver_id - 1) % 10 < 8 THEN 'COMFORT'
            WHEN (d.driver_id - 1) % 10 = 8 THEN 'BIKE' ELSE 'VAN' END,
       (ARRAY['LAG','ABJ','PHC','IBD','KAN'])[d.city_id] || '-' || lpad(d.driver_id::text, 5, '0') || 'SM',
       CASE (d.driver_id - 1) % 10 WHEN 8 THEN 'Bajaj' WHEN 9 THEN 'Toyota' ELSE (ARRAY['Toyota','Honda','Kia','Hyundai','Lexus'])[1 + d.driver_id % 5] END,
       CASE (d.driver_id - 1) % 10 WHEN 8 THEN 'Boxer' WHEN 9 THEN 'Hiace' ELSE (ARRAY['Corolla','Accord','Rio','Elantra','ES 350'])[1 + d.driver_id % 5] END,
       2012 + (d.driver_id % 13), true
FROM driver d;
-- 300 older, inactive vehicles (drivers who changed cars).
SELECT setval(pg_get_serial_sequence('swiftmove.vehicle', 'vehicle_id'), 5000);
INSERT INTO vehicle (driver_id, category_code, plate_no, make, model, model_year, is_active)
SELECT g * 16, 'ECONOMY', 'OLD-' || lpad(g::text, 5, '0') || 'SM', 'Toyota', 'Camry', 2008 + g % 6, false
FROM generate_series(1, 300) g;

-- ---------- Trips (1,000,000) ----------
CREATE TEMP TABLE trip_gen AS
SELECT g, random() AS r_city, random() AS r_rider, random() AS r_cat, random() AS r_type,
       random() AS r_drv, random() AS r_pz, random() AS r_dz, random() AS r_dist, random() AS r_dur,
       random() AS r_stat, random() AS r_t1, random() AS r_t2, random() AS r_j1, random() AS r_j2,
       random() AS r_j3, random() AS r_j4
FROM generate_series(1, 1000000) g;

INSERT INTO trip (trip_id, trip_type, rider_id, driver_id, vehicle_id, category_code, pickup_zone_id, dropoff_zone_id,
                  pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, status, requested_at, accepted_at, started_at,
                  completed_at, cancelled_at, distance_km, duration_min, fare_amount) OVERRIDING SYSTEM VALUE
SELECT g, ttype, rider_id,
       CASE WHEN has_driver THEN driver_id END, CASE WHEN has_driver THEN driver_id END,
       cat, pz, dz,
       pz_lat + (r_j1 - 0.5) * 0.02, pz_lng + (r_j2 - 0.5) * 0.02,
       dz_lat + (r_j3 - 0.5) * 0.02, dz_lng + (r_j4 - 0.5) * 0.02,
       status, req,
       CASE WHEN has_driver THEN req + (1 + r_t1 * 5) * interval '1 minute' END,
       CASE WHEN status IN ('in_progress', 'completed') THEN req + (3 + r_t1 * 5 + r_t2 * 10) * interval '1 minute' END,
       CASE WHEN status = 'completed' THEN req + (3 + r_t1 * 5 + r_t2 * 10 + dur) * interval '1 minute' END,
       CASE WHEN status = 'cancelled' THEN req + (2 + r_t2 * 8) * interval '1 minute' END,
       CASE WHEN status = 'completed' THEN dist END,
       CASE WHEN status = 'completed' THEN dur END,
       CASE WHEN status = 'completed' THEN greatest(sc.minimum_fare, round(sc.base_fare + sc.per_km * dist + sc.per_minute * dur, -1)) END
FROM (
  SELECT t.*, cr.city_id,
         CASE WHEN r_type < 0.15 THEN 'delivery' ELSE 'ride' END AS ttype,
         -- skewed: low ids within a city are heavy users
         cr.r_lo + floor(cr.r_n * power(r_rider, 1.8))::int AS rider_id,
         c.cat,
         cr.d_lo + 10 * floor(r_drv * (cr.d_n / 10))::int +
           CASE c.cat WHEN 'ECONOMY' THEN floor(r_drv * 6000)::int % 6 WHEN 'COMFORT' THEN 6 + floor(r_drv * 2000)::int % 2
                      WHEN 'BIKE' THEN 8 ELSE 9 END AS driver_id,
         cr.z_lo + floor(r_pz * cr.z_n)::int AS pz,
         cr.z_lo + floor(r_dz * cr.z_n)::int AS dz,
         round((1 + 24 * power(r_dist, 1.5))::numeric, 2) AS dist,
         round((5 + 2.4 * (1 + 24 * power(r_dist, 1.5)) + 10 * r_dur)::numeric, 1) AS dur,
         timestamptz '2025-10-10 06:00+01' + (g::numeric / 1000000) * interval '365 days' + (r_t1 * 30) * interval '1 second' AS req,
         CASE WHEN g > 999400 THEN (CASE WHEN r_stat < 0.5 THEN 'requested' WHEN r_stat < 0.75 THEN 'accepted' ELSE 'in_progress' END)
              WHEN r_stat < 0.10 THEN 'cancelled' ELSE 'completed' END AS status
  FROM trip_gen t
  JOIN city_range cr ON t.r_city < cr.cum AND t.r_city >= cr.cum - cr.weight
  CROSS JOIN LATERAL (SELECT CASE WHEN t.r_type < 0.15 THEN (CASE WHEN t.r_cat < 0.6 THEN 'BIKE' ELSE 'VAN' END)
                                  WHEN t.r_cat < 0.70 THEN 'ECONOMY' WHEN t.r_cat < 0.92 THEN 'COMFORT' ELSE 'BIKE' END AS cat) c
) x
JOIN service_category sc ON sc.category_code = x.cat
JOIN zone pzz ON pzz.zone_id = x.pz
JOIN zone dzz ON dzz.zone_id = x.dz
CROSS JOIN LATERAL (SELECT pzz.centre_lat AS pz_lat, pzz.centre_lng AS pz_lng, dzz.centre_lat AS dz_lat, dzz.centre_lng AS dz_lng,
                           (x.status IN ('accepted', 'in_progress', 'completed') OR (x.status = 'cancelled' AND x.r_t2 < 0.5)) AS has_driver) j
ORDER BY g;

DROP TABLE trip_gen;
SELECT setval(pg_get_serial_sequence('swiftmove.trip', 'trip_id'), (SELECT max(trip_id) FROM trip));
SELECT setval(pg_get_serial_sequence('swiftmove.rider', 'rider_id'), 50000);
SELECT setval(pg_get_serial_sequence('swiftmove.driver', 'driver_id'), 5000);

-- ---------- Parcels for delivery trips ----------
INSERT INTO parcel (trip_id, recipient_name, recipient_phone, size_class, declared_value, proof_of_delivery)
SELECT t.trip_id, f.n || ' ' || l.n, '+23470' || lpad((t.trip_id % 100000000)::text, 8, '0'),
       CASE WHEN t.category_code = 'BIKE' THEN (ARRAY['S','M'])[1 + t.trip_id % 2] ELSE (ARRAY['M','L'])[1 + t.trip_id % 2] END,
       (t.trip_id % 50) * 1000,
       CASE WHEN t.status = 'completed' THEN 'pod/' || t.trip_id || '.jpg' END
FROM trip t
JOIN fn f ON f.i = 1 + (t.trip_id * 3) % 40
JOIN ln l ON l.i = 1 + (t.trip_id * 7) % 30
WHERE t.trip_type = 'delivery';

-- ---------- Status history (one row per status reached) ----------
INSERT INTO trip_status_event (trip_id, seq, status, changed_at)
SELECT t.trip_id, e.seq, e.status, e.ts
FROM trip t
CROSS JOIN LATERAL (VALUES (1, 'requested', t.requested_at), (2, 'accepted', t.accepted_at), (3, 'in_progress', t.started_at),
                           (4, 'completed', t.completed_at), (4, 'cancelled', t.cancelled_at)) AS e(seq, status, ts)
WHERE e.ts IS NOT NULL;

-- ---------- Ratings ----------
-- ~3% of drivers (driver_id % 31 = 0) are consistently rated lower.
INSERT INTO rating (trip_id, direction, score, comment, created_at)
SELECT trip_id, 'rider_to_driver',
       CASE WHEN driver_id % 31 = 0 THEN (ARRAY[1,2,3,3,4,4,5])[1 + (trip_id % 7)]
            ELSE (ARRAY[5,5,5,5,5,5,4,4,4,3,5,5,4,5,5,2,5,4,5,1])[1 + (trip_id % 20)] END,
       CASE WHEN trip_id % 9 = 0 THEN 'Smooth ride' WHEN trip_id % 23 = 0 THEN 'Driver took a longer route' END,
       completed_at + interval '10 minutes'
FROM trip WHERE status = 'completed' AND trip_id % 10 < 7;
INSERT INTO rating (trip_id, direction, score, created_at)
SELECT trip_id, 'driver_to_rider', (ARRAY[5,5,5,4,5,4,5,3,5,5])[1 + (trip_id % 10)], completed_at + interval '12 minutes'
FROM trip WHERE status = 'completed' AND trip_id % 5 < 2;

-- ---------- Wallets ----------
INSERT INTO wallet (owner_kind) VALUES ('platform');                       -- wallet_id 1
INSERT INTO wallet (owner_kind, rider_id)  SELECT 'rider', rider_id FROM rider ORDER BY rider_id;
INSERT INTO wallet (owner_kind, driver_id) SELECT 'driver', driver_id FROM driver ORDER BY driver_id;

-- ---------- Payments ----------
-- wallet 40%, card 40%, cash 20%; 2% of card payments fail once before succeeding.
INSERT INTO payment (trip_id, method, amount, status, created_at, settled_at)
SELECT trip_id, 'card', fare_amount, 'failed', completed_at, completed_at + interval '20 seconds'
FROM trip WHERE status = 'completed' AND trip_id % 10 BETWEEN 4 AND 7 AND trip_id % 50 = 5;
INSERT INTO payment (trip_id, method, amount, status, created_at, settled_at)
SELECT trip_id, CASE WHEN trip_id % 10 < 4 THEN 'wallet' WHEN trip_id % 10 < 8 THEN 'card' ELSE 'cash' END,
       fare_amount, 'succeeded', completed_at, completed_at + interval '1 minute'
FROM trip WHERE status = 'completed'
ORDER BY trip_id;

-- ---------- Ledger ----------
-- Wallet payments move money rider -> driver (net) + platform (commission).
INSERT INTO wallet_ledger (wallet_id, payment_id, entry_type, amount, created_at)
SELECT w.wallet_id, p.payment_id, e.entry_type, e.amount, p.settled_at
FROM payment p
JOIN trip t ON t.trip_id = p.trip_id
JOIN service_category sc ON sc.category_code = t.category_code
CROSS JOIN LATERAL (VALUES
   ('rider',    'trip_debit',  -p.amount),
   ('driver',   'trip_credit', p.amount - round(p.amount * sc.commission_rate, 2)),
   ('platform', 'commission',  round(p.amount * sc.commission_rate, 2))) AS e(kind, entry_type, amount)
JOIN wallet w ON (e.kind = 'rider' AND w.rider_id = t.rider_id) OR (e.kind = 'driver' AND w.driver_id = t.driver_id)
              OR (e.kind = 'platform' AND w.owner_kind = 'platform')
WHERE p.method = 'wallet' AND p.status = 'succeeded';

-- Cash trips: the driver collected cash, so commission moves driver -> platform.
INSERT INTO wallet_ledger (wallet_id, payment_id, entry_type, amount, created_at)
SELECT w.wallet_id, p.payment_id, 'commission', CASE WHEN e.kind = 'driver' THEN -c ELSE c END, p.settled_at
FROM payment p
JOIN trip t ON t.trip_id = p.trip_id
JOIN service_category sc ON sc.category_code = t.category_code
CROSS JOIN LATERAL (SELECT round(p.amount * sc.commission_rate, 2) AS c) cc
CROSS JOIN LATERAL (VALUES ('driver'), ('platform')) AS e(kind)
JOIN wallet w ON (e.kind = 'driver' AND w.driver_id = t.driver_id) OR (e.kind = 'platform' AND w.owner_kind = 'platform')
WHERE p.method = 'cash' AND p.status = 'succeeded';

-- Rider top-ups: enough to cover what they spent, plus a remaining balance.
INSERT INTO wallet_ledger (wallet_id, entry_type, amount, created_at)
SELECT w.wallet_id, 'topup',
       coalesce(-sum(l.amount), 0) + 2000 + (w.rider_id % 19) * 1000,
       r.created_at + interval '1 hour'
FROM wallet w
JOIN rider r ON r.rider_id = w.rider_id
LEFT JOIN wallet_ledger l ON l.wallet_id = w.wallet_id AND l.entry_type = 'trip_debit'
WHERE w.owner_kind = 'rider'
GROUP BY w.wallet_id, w.rider_id, r.created_at;

-- Balances are the sum of each wallet's ledger (the invariant checked in Portfolio 3).
UPDATE wallet w SET balance = s.total, updated_at = now()
FROM (SELECT wallet_id, sum(amount) AS total FROM wallet_ledger GROUP BY wallet_id) s
WHERE s.wallet_id = w.wallet_id;

DROP TABLE city_range, first_names, last_names, fn, ln;
ANALYZE;

-- ---------- Summary ----------
SELECT 'city' AS table_name, count(*) FROM city UNION ALL SELECT 'zone', count(*) FROM zone
UNION ALL SELECT 'rider', count(*) FROM rider UNION ALL SELECT 'driver', count(*) FROM driver
UNION ALL SELECT 'vehicle', count(*) FROM vehicle UNION ALL SELECT 'trip', count(*) FROM trip
UNION ALL SELECT 'parcel', count(*) FROM parcel UNION ALL SELECT 'trip_status_event', count(*) FROM trip_status_event
UNION ALL SELECT 'rating', count(*) FROM rating UNION ALL SELECT 'wallet', count(*) FROM wallet
UNION ALL SELECT 'payment', count(*) FROM payment UNION ALL SELECT 'wallet_ledger', count(*) FROM wallet_ledger;
