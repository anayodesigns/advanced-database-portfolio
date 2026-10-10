-- =====================================================================
-- SwiftMove ride-hailing & parcel delivery platform
-- Portfolio 1: relational schema (PostgreSQL 17)
-- Normalised to 3NF / BCNF. See README.md for the normalisation steps.
-- =====================================================================

DROP SCHEMA IF EXISTS swiftmove CASCADE;
CREATE SCHEMA swiftmove;
SET search_path = swiftmove;

-- ---------- Reference data ------------------------------------------

CREATE TABLE city (
    city_id      SMALLINT     PRIMARY KEY,
    name         VARCHAR(60)  NOT NULL,
    state        VARCHAR(60)  NOT NULL,
    country_code CHAR(2)      NOT NULL DEFAULT 'NG',
    timezone     VARCHAR(40)  NOT NULL DEFAULT 'Africa/Lagos',
    CONSTRAINT uq_city_name UNIQUE (name, state)
);

-- A zone is a service area inside a city (e.g. Lekki Phase 1, Ikeja GRA).
CREATE TABLE zone (
    zone_id   INTEGER      PRIMARY KEY,
    city_id   SMALLINT     NOT NULL REFERENCES city (city_id),
    name      VARCHAR(80)  NOT NULL,
    centre_lat NUMERIC(9,6) NOT NULL CHECK (centre_lat BETWEEN -90 AND 90),
    centre_lng NUMERIC(9,6) NOT NULL CHECK (centre_lng BETWEEN -180 AND 180),
    CONSTRAINT uq_zone_name UNIQUE (city_id, name)
);

-- Fare rules depend only on the service category, so they live here
-- (removing the transitive dependency trip -> category -> base_fare).
CREATE TABLE service_category (
    category_code   VARCHAR(12)   PRIMARY KEY,           -- ECONOMY, COMFORT, BIKE, VAN
    description     VARCHAR(80)   NOT NULL,
    seats           SMALLINT      NOT NULL CHECK (seats BETWEEN 0 AND 8),
    base_fare       NUMERIC(10,2) NOT NULL CHECK (base_fare >= 0),
    per_km          NUMERIC(10,2) NOT NULL CHECK (per_km >= 0),
    per_minute      NUMERIC(10,2) NOT NULL CHECK (per_minute >= 0),
    minimum_fare    NUMERIC(10,2) NOT NULL CHECK (minimum_fare >= 0),
    commission_rate NUMERIC(4,3)  NOT NULL CHECK (commission_rate BETWEEN 0 AND 0.5)
);

-- ---------- People ----------------------------------------------------

CREATE TABLE rider (
    rider_id     BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    email        VARCHAR(160) NOT NULL,
    phone        VARCHAR(20)  NOT NULL,
    home_city_id SMALLINT     NOT NULL REFERENCES city (city_id),
    status       VARCHAR(10)  NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active', 'suspended', 'closed')),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_rider_email UNIQUE (email),
    CONSTRAINT uq_rider_phone UNIQUE (phone),
    CONSTRAINT ck_rider_phone CHECK (phone ~ '^\+234[0-9]{10}$')
);

CREATE TABLE driver (
    driver_id    BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    email        VARCHAR(160) NOT NULL,
    phone        VARCHAR(20)  NOT NULL,
    licence_no   VARCHAR(20)  NOT NULL,
    city_id      SMALLINT     NOT NULL REFERENCES city (city_id),
    status       VARCHAR(12)  NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'approved', 'suspended', 'offboarded')),
    joined_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_driver_email   UNIQUE (email),
    CONSTRAINT uq_driver_phone   UNIQUE (phone),
    CONSTRAINT uq_driver_licence UNIQUE (licence_no),
    CONSTRAINT ck_driver_phone CHECK (phone ~ '^\+234[0-9]{10}$')
);

CREATE TABLE vehicle (
    vehicle_id    BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    driver_id     BIGINT      NOT NULL REFERENCES driver (driver_id),
    category_code VARCHAR(12) NOT NULL REFERENCES service_category (category_code),
    plate_no      VARCHAR(12) NOT NULL,
    make          VARCHAR(40) NOT NULL,
    model         VARCHAR(40) NOT NULL,
    model_year    SMALLINT    NOT NULL CHECK (model_year BETWEEN 2000 AND 2027),
    is_active     BOOLEAN     NOT NULL DEFAULT true,
    CONSTRAINT uq_vehicle_plate UNIQUE (plate_no)
);
-- A driver may own several vehicles but drive only one active vehicle.
CREATE UNIQUE INDEX uq_vehicle_one_active_per_driver ON vehicle (driver_id) WHERE is_active;

-- ---------- Trips (rides and parcel deliveries) -----------------------

CREATE TABLE trip (
    trip_id         BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_type       VARCHAR(8)    NOT NULL DEFAULT 'ride' CHECK (trip_type IN ('ride', 'delivery')),
    rider_id        BIGINT        NOT NULL REFERENCES rider (rider_id),
    driver_id       BIGINT        REFERENCES driver (driver_id),      -- NULL until matched
    vehicle_id      BIGINT        REFERENCES vehicle (vehicle_id),
    category_code   VARCHAR(12)   NOT NULL REFERENCES service_category (category_code),
    pickup_zone_id  INTEGER       NOT NULL REFERENCES zone (zone_id),
    dropoff_zone_id INTEGER       NOT NULL REFERENCES zone (zone_id),
    pickup_lat      NUMERIC(9,6)  NOT NULL,
    pickup_lng      NUMERIC(9,6)  NOT NULL,
    dropoff_lat     NUMERIC(9,6)  NOT NULL,
    dropoff_lng     NUMERIC(9,6)  NOT NULL,
    status          VARCHAR(12)   NOT NULL DEFAULT 'requested'
                    CHECK (status IN ('requested', 'accepted', 'in_progress', 'completed', 'cancelled')),
    requested_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    accepted_at     TIMESTAMPTZ,
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    distance_km     NUMERIC(7,2)  CHECK (distance_km >= 0),
    duration_min    NUMERIC(7,1)  CHECK (duration_min >= 0),
    fare_amount     NUMERIC(12,2) CHECK (fare_amount >= 0),
    -- Business rules enforced by the database, not just the app:
    CONSTRAINT ck_trip_matched CHECK (status IN ('requested', 'cancelled') OR (driver_id IS NOT NULL AND vehicle_id IS NOT NULL)),
    CONSTRAINT ck_trip_completed CHECK (status <> 'completed' OR (completed_at IS NOT NULL AND fare_amount IS NOT NULL AND distance_km IS NOT NULL)),
    CONSTRAINT ck_trip_cancelled CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL),
    CONSTRAINT ck_trip_timeline CHECK (
        (accepted_at  IS NULL OR accepted_at  >= requested_at) AND
        (started_at   IS NULL OR started_at   >= accepted_at)  AND
        (completed_at IS NULL OR completed_at >= started_at))
);

-- Parcel details exist only for delivery trips (1:0..1 with trip).
CREATE TABLE parcel (
    trip_id          BIGINT       PRIMARY KEY REFERENCES trip (trip_id) ON DELETE CASCADE,
    recipient_name   VARCHAR(120) NOT NULL,
    recipient_phone  VARCHAR(20)  NOT NULL CHECK (recipient_phone ~ '^\+234[0-9]{10}$'),
    size_class       CHAR(1)      NOT NULL CHECK (size_class IN ('S', 'M', 'L')),
    declared_value   NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (declared_value >= 0),
    proof_of_delivery VARCHAR(200)
);

-- Full audit trail of status changes (the trip row holds only the current status).
CREATE TABLE trip_status_event (
    trip_id    BIGINT      NOT NULL REFERENCES trip (trip_id) ON DELETE CASCADE,
    seq        SMALLINT    NOT NULL,
    status     VARCHAR(12) NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (trip_id, seq)
);

-- Each side rates the other at most once per trip.
CREATE TABLE rating (
    trip_id    BIGINT      NOT NULL REFERENCES trip (trip_id) ON DELETE CASCADE,
    direction  VARCHAR(16) NOT NULL CHECK (direction IN ('rider_to_driver', 'driver_to_rider')),
    score      SMALLINT    NOT NULL CHECK (score BETWEEN 1 AND 5),
    comment    VARCHAR(500),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (trip_id, direction)
);

-- ---------- Money: wallets, ledger, payments --------------------------

-- One wallet per rider, one per driver, plus the platform's own account.
CREATE TABLE wallet (
    wallet_id   BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_kind  VARCHAR(8)    NOT NULL CHECK (owner_kind IN ('rider', 'driver', 'platform')),
    rider_id    BIGINT        REFERENCES rider (rider_id),
    driver_id   BIGINT        REFERENCES driver (driver_id),
    currency    CHAR(3)       NOT NULL DEFAULT 'NGN',
    balance     NUMERIC(14,2) NOT NULL DEFAULT 0,
    version     INTEGER       NOT NULL DEFAULT 0,     -- for optimistic locking (Portfolio 3)
    updated_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT ck_wallet_owner CHECK (
        (owner_kind = 'rider'    AND rider_id IS NOT NULL AND driver_id IS NULL) OR
        (owner_kind = 'driver'   AND driver_id IS NOT NULL AND rider_id IS NULL) OR
        (owner_kind = 'platform' AND rider_id IS NULL AND driver_id IS NULL)),
    -- Riders can never go negative; drivers may carry a small cash-commission debt.
    CONSTRAINT ck_wallet_balance CHECK (owner_kind <> 'rider' OR balance >= 0),
    CONSTRAINT uq_wallet_rider  UNIQUE (rider_id),
    CONSTRAINT uq_wallet_driver UNIQUE (driver_id)
);
CREATE UNIQUE INDEX uq_wallet_single_platform ON wallet (owner_kind) WHERE owner_kind = 'platform';

CREATE TABLE payment (
    payment_id  BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_id     BIGINT        NOT NULL REFERENCES trip (trip_id),
    method      VARCHAR(8)    NOT NULL CHECK (method IN ('wallet', 'card', 'cash')),
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    status      VARCHAR(10)   NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'succeeded', 'failed', 'refunded')),
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    settled_at  TIMESTAMPTZ,
    CONSTRAINT ck_payment_settled CHECK (status = 'pending' OR settled_at IS NOT NULL)
);
-- At most one successful payment per trip (retries leave failed rows behind).
CREATE UNIQUE INDEX uq_payment_one_success ON payment (trip_id) WHERE status = 'succeeded';

-- Double-entry style ledger: every money movement is an immutable row.
CREATE TABLE wallet_ledger (
    entry_id    BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wallet_id   BIGINT        NOT NULL REFERENCES wallet (wallet_id),
    payment_id  BIGINT        REFERENCES payment (payment_id),
    entry_type  VARCHAR(12)   NOT NULL CHECK (entry_type IN ('topup', 'trip_debit', 'trip_credit', 'commission', 'payout', 'refund')),
    amount      NUMERIC(14,2) NOT NULL CHECK (amount <> 0),     -- signed: negative = debit
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- ---------- Foreign-key indexes (PostgreSQL does not create them) -----
CREATE INDEX ix_zone_city        ON zone (city_id);
CREATE INDEX ix_vehicle_driver   ON vehicle (driver_id);
CREATE INDEX ix_payment_trip     ON payment (trip_id);
CREATE INDEX ix_ledger_wallet    ON wallet_ledger (wallet_id);
CREATE INDEX ix_ledger_payment   ON wallet_ledger (payment_id);
-- trip foreign keys are indexed deliberately in Portfolio 2 (to show the before/after).

-- ---------- Derived data as views, not stored columns -----------------
-- Average rating is derived, so it is computed rather than stored on driver
-- (storing it would create an update anomaly).
CREATE VIEW driver_rating AS
SELECT t.driver_id, round(avg(r.score), 2) AS avg_score, count(*) AS ratings
FROM rating r JOIN trip t ON t.trip_id = r.trip_id
WHERE r.direction = 'rider_to_driver'
GROUP BY t.driver_id;

COMMENT ON TABLE trip IS 'One row per ride or delivery request; current status only, history in trip_status_event.';
COMMENT ON TABLE wallet_ledger IS 'Append-only money movements. Sum of amounts per wallet must equal wallet.balance.';
