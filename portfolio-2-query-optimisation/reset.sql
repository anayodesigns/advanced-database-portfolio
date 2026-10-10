-- Remove every optimisation object so the "before" run starts from the Portfolio 1 baseline
-- (trip has only its primary key; rider has only its UNIQUE(email) / UNIQUE(phone) indexes).
SET search_path = swiftmove;
DROP INDEX IF EXISTS ix_trip_rider_requested, ix_trip_driver_completed, ix_trip_open_requests,
  ix_rating_recent_r2d, ix_rider_email_lower, ix_trip_requested_brin, ix_trip_requested_btree, ix_trip_driver;
DROP MATERIALIZED VIEW IF EXISTS mv_city_monthly_revenue;
VACUUM ANALYZE trip;
