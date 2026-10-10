# Portfolio 4 — NoSQL and Advanced Data Models

The same SwiftMove case study, modelled in **MongoDB 8.0**. The trips, drivers and riders are exported straight from the Portfolio 1 PostgreSQL database ([`export_from_postgres.sql`](export_from_postgres.sql)), so both systems hold the same facts:
- **107,535 trips** (everything requested since 1 Sep 2026)
- **5,000 drivers**
- **50,000 riders**

Four NoSQL data-model patterns are used, each for the part of SwiftMove it suits best:

| Pattern | Collection | SwiftMove use |
|---|---|---|
| **Document** (embedding) | `trips` | Trip timeline, receipt and support view in one read |
| **Geospatial document** | `drivers` | "Find the nearest available driver" for dispatch |
| **Key-value** (with TTL) | `driver_presence` | Online/offline heartbeats that expire by themselves |
| **Graph** (`$graphLookup`) | `riders.referred_by` | Referral network: ambassadors' downline, a rider's upline |
| **Column-family** | *design only* (section 6) | High-volume GPS pings, if SwiftMove adds Cassandra |

## 1. Files

| File | Purpose |
|---|---|
| [`export_from_postgres.sql`](export_from_postgres.sql) | Builds one JSON document per trip from 9 relational tables (NDJSON) |
| [`load.js`](load.js) | Creates `trips` with JSON-Schema validation, loads all collections |
| [`demos.js`](demos.js) | Demonstrations 0–9 (validation, indexes and explain, geo, atomic update, aggregation, TTL, graph) |
| [`run.sh`](run.sh) | Export → load → demos |
| [`sample-documents.json`](sample-documents.json) | Example ride, delivery, driver and rider documents |
| [`evidence/load-output.txt`](evidence/load-output.txt), [`evidence/demo-output.txt`](evidence/demo-output.txt) | Output of the last run |

The 102 MB `data/*.ndjson` export isn't committed; `run.sh` regenerates it in about 3 seconds.

## 2. Document design for `trips`

```text
trip {
  _id: 892470, type: "ride"|"delivery", status, category, city, requested_at: Date,
  rider:   { rider_id, name, phone },                       ← snapshot (embedded copy)
  driver:  { driver_id, name, vehicle: { plate, make, model } },   ← snapshot, absent until matched
  pickup:  { zone, location: GeoJSON Point [lng, lat] },
  dropoff: { zone, location: GeoJSON Point },
  status_history: [ { status, at }, ... ],                  ← was table trip_status_event
  fare:    { amount, currency, distance_km, duration_min, commission },
  payment: { method, status, settled_at },                  ← successful payment only
  ratings: { rider_to_driver: { score, comment }, driver_to_rider: { score } },   ← was table rating
  parcel:  { recipient, recipient_phone, size, declared_value }   ← only on deliveries
}
```

**Embed or reference: the decisions**

| Data | Decision | Reason |
|---|---|---|
| status history, ratings, payment, parcel | **Embed** | Owned by exactly one trip, bounded in size (≤ 5 status events, ≤ 2 ratings), and always read with the trip. These were 1:N or 1:0..1 child tables in SQL. |
| rider name/phone, driver name, vehicle plate | **Embed a snapshot** | A receipt must show the driver and plate *as they were on that trip*. Copying them in is deliberate denormalisation: if a driver later changes cars, old trips correctly keep the old plate. |
| full rider/driver profiles, wallets | **Reference** by `rider_id` / `driver_id` | Unbounded, change often, and are shared by many trips. Wallet money stays in PostgreSQL (section 5). |
| the trip itself | **Top-level document**, `_id` = PostgreSQL `trip_id` | Easy to reconcile both systems |

**Flexible schema.** Deliveries carry a `parcel` sub-document and rides don't (16,148 against 91,387 documents). In the relational model this needed a separate `parcel` table and a join.

**Validation.** MongoDB is schema-flexible, not schema-less. `trips` uses `$jsonSchema`: required fields, enums for status, category and type, GeoJSON structure, `fare.amount ≥ 0`, and dates as BSON dates. It also carries the Portfolio 1 business rule *"a completed trip must have a driver and a fare"*. `$jsonSchema` has no if/then, so that rule is a `$or` query clause combined with the schema under `$and`. Both test inserts in demo 2 are rejected with error 121, and MongoDB reports which clause failed.

## 3. Results

| # | Demonstration | Result (from [`evidence/demo-output.txt`](evidence/demo-output.txt)) |
|---|---|---|
| 1 | Whole trip in one read | One `findOne` returns trip + rider + driver + vehicle + zones + 5 status events + fare + payment + ratings + parcel. The same view in PostgreSQL joins 9 tables. |
| 2 | Schema validation | Invalid status → **rejected**; completed trip without driver/fare → **rejected** (`$or` clause not satisfied) |
| 3 | Index (rider history, same as Postgres Q1) | Before: `COLLSCAN`, **107,535 docs examined**, 25 ms. After `{rider.rider_id: 1, requested_at: -1}`: `IXSCAN`, **20 keys / 20 docs**, 1 ms. |
| 4 | Nearest available driver | `$geoNear` on a 2dsphere compound index returns the 5 closest available ECONOMY drivers within 3 km of Lekki Phase 1 (225 m, 278 m, 554 m, 623 m, 637 m). `GEO_NEAR_2DSPHERE`, **16 docs examined out of 5,000**, under 1 ms. |
| 5 | Atomic single-document update | The first dispatcher's `findOneAndUpdate({_id, status: "requested"}, …)` sets the driver and pushes a status event in one atomic write. The second returns **`null`**: the condition no longer matches, so there's no double assignment. |
| 6 | Aggregation pipeline | Top 5 Lagos drivers by net earnings, last 30 days: `$match → $group → $sort → $limit`, with average rating from the embedded `ratings`. `$facet` returns the busiest pickup zone per city and the payment-method mix in one pass. |
| 7 | Key-value + TTL | 3 heartbeat keys (`driver:<id>`); 2 drivers keep refreshing every 10 s, 1 stops. After 65 s only the 2 live keys remain: **`driver:0069` expired automatically** (TTL index, 30 s). |
| 8 | Graph traversal | Ambassador rider 16 has 244 direct referrals and **784 riders in a 4-level network** (244 / 329 / 136 / 75 per level). Reverse traversal gives rider 20001's referral chain 17540 → 18 → 17 → 7. |
| 9 | Storage | 107,535 documents, average 914 bytes; 93.8 MB of data, **26.2 MB on disk** (WiredTiger snappy compression), 2.7 MB indexes |

## 4. Why each model suits its SwiftMove workload

**Document model → trips.** A trip is written once, updated a few times while it runs (status changes), then mostly *read as a whole*: receipt screen, support agent view, dispute handling, analytics export. Embedding gives:
1. One read, no joins, for the most common access pattern.
2. **Atomic updates within a document** (demo 5) without a multi-statement transaction. MongoDB guarantees single-document atomicity.
3. Natural polymorphism (rides against deliveries).
4. Easy horizontal scaling: a trip and all its parts live together, so the collection shards cleanly (Portfolio 5).

The cost is duplicated rider and driver snapshots. Here that's intended (historical accuracy), but a profile *correction* such as a misspelt name wouldn't update old trips.

**Geospatial → dispatch.** Matching is the core real-time operation. The 2dsphere index stores locations as S2 cells. `$geoNear` walks outward from the pickup point and stops after the 5 nearest matches, so it examined 16 of 5,000 drivers. Doing the same in plain PostgreSQL needs the PostGIS extension, or a bounding-box plus distance calculation over many rows.

**Key-value + TTL → presence.** Heartbeats are tiny, extremely frequent (every few seconds per driver), only accessed by key, and only matter for about 30 seconds. A TTL index deletes expired keys in the background, so "who is online" never needs a cleanup job. At larger scale this belongs in an in-memory store such as **Redis** (`SET driver:4999 … EX 30`). The access pattern is the same; MongoDB is used here to keep the stack to the tools installed.

**Graph → referrals.** "Everyone in rider 16's network up to 4 levels deep" is recursive. `$graphLookup` follows `referred_by` edges with a `depthField`, so one query gives the network size per level, and the reverse direction gives the upline (useful for multi-level referral bonuses). PostgreSQL can do this with `WITH RECURSIVE`. For heavy graph analytics (fraud rings, shared devices across accounts), a native graph database (Neo4j) would be the better fit.

## 5. Relational vs NoSQL for SwiftMove: polyglot persistence

| Concern | PostgreSQL (Portfolios 1–3) | MongoDB (this portfolio) |
|---|---|---|
| Wallets, payments, ledger | **Use this.** Multi-row ACID transactions, CHECK constraints, serializable isolation; Portfolio 3 proved the invariants under 16-way concurrency. | Multi-document transactions exist but need a replica set, and money rules like `balance ≥ 0` across documents are harder to enforce |
| Trip history / receipts / support view | 8–9 joins per view | **One document read** |
| Nearest-driver search | Needs PostGIS | **Built-in 2dsphere + `$geoNear`** |
| Online presence | Constant UPDATE churn and vacuum load | **TTL key-value** (or Redis) |
| Ad-hoc analytics, reporting | **SQL, window functions, materialized views** | Aggregation pipeline (good, but less expressive for complex joins) |
| Schema change (e.g. add a parcel field) | Migration (`ALTER TABLE`) | Just write it (validator updated deliberately) |
| Consistency of copied data | Normalised, one source of truth | Snapshots can diverge from profiles by design |

**Recommendation:** PostgreSQL stays the **system of record** for money and core entities. MongoDB serves read-heavy, document-shaped, geo and ephemeral workloads, fed by change-data-capture from PostgreSQL. The export script here is a batch version of that pipeline. Using each database for what it does best is the polyglot-persistence approach most ride-hailing platforms take.

## 6. Column-family design (not implemented)

At production scale, live GPS pings (one per driver every 4 s ≈ 100M rows/day for 5,000 drivers at peak) would overwhelm both databases above. A wide-column store such as **Apache Cassandra** fits: write-optimised, partitioned by key, with time-ordered rows inside a partition.

```sql
-- CQL design: one partition per driver per day; rows clustered by time (newest first)
CREATE TABLE swiftmove.driver_location_by_day (
    driver_id  bigint,
    day        date,
    ts         timestamp,
    lat        double,
    lng        double,
    speed_kmh  float,
    trip_id    bigint,
    PRIMARY KEY ((driver_id, day), ts)
) WITH CLUSTERING ORDER BY (ts DESC)
  AND default_time_to_live = 2592000;   -- keep 30 days

-- Query it serves: "replay driver 4999's route on 10 Oct 2026" — a single-partition, sequential read
SELECT ts, lat, lng FROM swiftmove.driver_location_by_day WHERE driver_id = 4999 AND day = '2026-10-10';
```

The partition key `(driver_id, day)` bounds each partition (about 21,600 rows/day) and spreads writes across the cluster. As with all Cassandra modelling, the table is designed *from the query*. This design was **not implemented**, because Cassandra isn't installed in this environment.

## 7. Limitations

- MongoDB runs here as a **standalone** server, so multi-document transactions and replication aren't available. Portfolio 5 runs a replica set and a sharded cluster.
- Rider and driver snapshots aren't kept in sync with later profile edits. A CDC pipeline would need a policy for corrections.
- Driver locations and referral links are synthetic, generated in `load.js` with a fixed seed. Trip, rider and driver facts come from PostgreSQL.

## 8. Reproduce

```bash
. scripts/env.sh
portfolio-4-nosql/run.sh          # starts MongoDB, exports from Postgres, loads, runs demos (~80 s)
```
