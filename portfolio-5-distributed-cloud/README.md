# Portfolio 5 — Distributed and Cloud Database Exercise

Parts A–D build **real multi-node clusters** for SwiftMove on one machine: separate server processes, ports and data directories. Part E is the cloud deployment design they map onto.

| Part | What | Status |
|---|---|---|
| **A** | PostgreSQL streaming replication: primary → hot standby, sync vs async, crash + failover | Implemented, evidence below |
| **B** | MongoDB 3-member replica set: elections, write concerns, loss of majority | Implemented |
| **C** | MongoDB sharded cluster: config server + 2 shards + mongos router, zone sharding by city | Implemented |
| **D** | PostgreSQL range partitioning: pruning and archiving | Implemented |
| **E** | Cloud deployment design: [`cloud-deployment-design.md`](cloud-deployment-design.md) | **Design only, not deployed** (no cloud account was used) |

```text
Part A                          Part B                         Part C
┌──────────────┐  WAL stream    ┌────────┐ ┌────────┐ ┌────────┐   app ─▶ mongos :27040
│ primary 5433 │ ─────────────▶ │ :27021 │ │ :27022 │ │ :27023 │            │
└──────────────┘  slot replica1 └────────┘ └────────┘ └────────┘    ┌───────┴────────┐
┌──────────────┐                 replica set rs0 (1 primary,        ▼                ▼
│ standby 5434 │ read-only       2 secondaries, majority votes)  shard shA         shard shB
└──────────────┘                                                 zone LAGOS        zone REST_OF_NIGERIA
                                                                 config servers cfg :27030
```

## 1. Files

| File | Purpose |
|---|---|
| [`scripts/a_postgres_replication.sh`](scripts/a_postgres_replication.sh) | Builds the standby, runs A1–A9, restores the original primary afterwards |
| [`scripts/b_mongo_replica_set.sh`](scripts/b_mongo_replica_set.sh) | Builds rs0, runs B1–B6 (including `kill -9` of members) |
| [`scripts/c_mongo_sharding.sh`](scripts/c_mongo_sharding.sh) | Builds the sharded cluster, zones, load, routing tests (C1–C5) |
| [`scripts/d_postgres_partitioning.sql`](scripts/d_postgres_partitioning.sql) | Monthly partitions, pruning, detach (D1–D5) |
| [`run_all.sh`](run_all.sh) | Runs A–D (about 4 minutes) |
| [`evidence/`](evidence) | Output of each part |
| [`cloud-deployment-design.md`](cloud-deployment-design.md) | Part E |

## 2. Part A — PostgreSQL streaming replication ([evidence](evidence/a-postgres-replication.txt))

| Step | Result |
|---|---|
| A1 Build standby | `pg_basebackup -R -X stream -C -S replica1` copied **1.3 GB in 4 s** and created a **replication slot**, so the primary keeps WAL until the standby has it |
| A2 Status | `state = streaming`, `sync_state = async`, `lag_bytes = 0`; standby reports `pg_is_in_recovery() = t` |
| A3 Visibility delay | 5 probe rows written on the primary were visible on the standby on the first poll, **24–33 ms** after the write. That time is mostly the cost of starting a new `psql` connection, so it's an upper bound; the real apply delay is lower. |
| A4 Read-only standby | `SELECT count(*) FROM trip` works (1,020,007); `UPDATE wallet …` fails with **`cannot execute UPDATE in a read-only transaction`** |
| A5 Read scaling | The finance dashboard (Portfolio 2 Q4b) is served by the standby |
| A6 Async vs sync commit (pgbench `pay_trip`, 4 clients, 10 s each) | Evidence run: **21,391 → 17,505 TPS** (−18%), latency 0.187 → 0.229 ms. An earlier run of the same script (output overwritten by the rerun) showed 26,204 → 12,974 TPS (−50%). The cost varies between runs on one machine, but it is always a loss. |
| A7 Lag under load | During a 2M-row bulk insert, lag was **5.6–7.3 MB of WAL** (replay lag up to 0.25 s) and returned to **0** before the load finished sampling (t+5 s) |
| A8 Failover | A payment was committed → primary killed with `pg_ctl stop -m immediate` (crash, no clean shutdown) → standby promoted in **121 ms** (165 ms in an earlier run) → the **payment is present** on the new primary, which accepts writes; ledger/balance mismatches = **0** |
| A9 Clean-up | The promoted copy is retired and the original primary restarted (it has every commit up to the crash), so Portfolios 1–4 keep working on port 5433 |

**Analysis.**
- **Asynchronous** replication (the default) gives the best write latency, but a crash of the primary can lose the last few transactions not yet streamed. That's a non-zero RPO.
- **Synchronous** replication (`synchronous_standby_names`) makes each COMMIT wait for the standby to flush WAL, giving RPO = 0. The cost here was 18% of throughput in the evidence run (50% in an earlier run), and across real availability zones the network round trip adds more.
- For SwiftMove the **money tables justify synchronous commit**; the cost is more than offset by the lock-hotspot fix found in Portfolio 3.
- A failover test only counts if data committed *before* the crash is there *after* it, which A8 checks.
- In production the old primary must not simply be restarted, as A9 does here; it would be rebuilt with `pg_rewind` to avoid split brain (Part E §8).

## 3. Part B — MongoDB replica set ([evidence](evidence/b-mongo-replica-set.txt))

| Step | Result |
|---|---|
| B1 Initiate | 3 members elect `localhost:27021` as PRIMARY; `electionTimeoutMillis = 10000`, heartbeat every 2 s |
| B2 Majority writes | 20,000 trips inserted with `w: "majority"` in 1.1 s; every member reports 20,000; secondaries **0 s behind** |
| B3 Write concern cost | 2,000 single inserts: **`w:1` 0.29 ms** against **`w:"majority"` 6.76 ms** per insert (about 23×) |
| B4 Failover | Primary killed with **SIGKILL** → new primary `localhost:27022` **elected after 11.1 s** (about the 10 s election timeout + detection) → the majority write made just before the crash **survived**; majority writes work with 2 of 3 members |
| B5 Loss of majority | Second member killed → the last member steps down to **SECONDARY**; writes fail with **`NotWritablePrimary`**; **reads still served** (20,001 docs, possibly stale) |
| B6 Recovery | Both members restarted, all 3 healthy after **6.8 s**; the old primary rejoined as a secondary; every member has 20,001 docs including the post-failover write |

**Analysis.**
- A replica set needs a **majority of voting members** (2 of 3) to elect a primary. That's why production uses an odd number of members spread over 3 availability zones: losing any one zone still leaves a majority.
- Losing the majority (B5) shows the **CAP choice**: MongoDB gives up write *availability* to keep *consistency*, so there's never two primaries. Reads from secondaries stay available, trading consistency for availability for read-only use.
- **Write concern** sets how durable an acknowledgement is. `w:1` is about 23× faster but can be **rolled back** if the primary fails before replicating. `w:"majority"` writes can't be rolled back by a failover, as the B4 marker shows.
- SwiftMove uses majority for trip state changes and `w:1` for disposable telemetry.

## 4. Part C — MongoDB sharded cluster ([evidence](evidence/c-mongo-sharding.txt))

**Shard-key choice: `{city: 1, _id: 1}` with zones.** Every dispatch, rider and driver query is within one city. Using the city as the shard-key prefix keeps a city's data on one shard, and zones pin **Lagos** (half of all trips) to **shA** and all other cities to **shB**. Adding `_id` makes the key high-cardinality, so a city's data can still be split into many chunks; a bare `{city}` key would create unsplittable "jumbo" chunks.

| Step | Result |
|---|---|
| C1 Topology | Config server replica set `cfg` (:27030), shards `shA` (:27031) and `shB` (:27032), router `mongos` (:27040) |
| C2 Zones | `LAGOS: {Lagos, MinKey} → {"Lagos\u0000", MinKey}` on shA; `REST_OF_NIGERIA` = everything else, on shB |
| C3 Distribution | 107,535 trips through the router in 4.8 s → **shA: 53,764 trips, only Lagos; shB: 53,771 trips, Abuja/Ibadan/Kano/Port Harcourt** (49.99% / 50.01%) |
| C4 Routing | `city = "Lagos" AND rider = …` → **`SINGLE_SHARD` (shA only)**. `rider = …` without the shard key → **`SHARD_MERGE` across both shards** (scatter-gather). `city IN ["Kano","Abuja"]` → **`SINGLE_SHARD` (shB)**. `$group` by city → partial aggregation on each shard, merged on mongos. |
| C5 Hashed key | `{_id: "hashed"}` spreads 50,000 docs evenly (25,023 / 24,977), but `city = "Lagos"` becomes **scatter-gather to both shards** |

**A bug found and fixed.** In the first run the Lagos zone ended at `{city: "Lagos", _id: MaxKey}`, and `city = "Lagos"` queries were sent to **both** shards. The query's bounds are inclusive at `{Lagos, MaxKey}`, which is also the first key of the next chunk, owned by shB. Ending the zone at `"Lagos\u0000"` (the smallest string greater than "Lagos") made the routing `SINGLE_SHARD`. Both runs are described here; the evidence file is from the fixed run.

**Analysis.**
- **Targeted** queries contact one shard and scale with the number of shards. **Scatter-gather** queries contact all of them and get slower as shards are added.
- The shard key must therefore match the most frequent query predicate: city here.
- The trade-off is **balance**. Zone sharding by city gives locality and data residency (a future Ghana zone could live on in-country servers), but a city that grows faster than the others becomes a hot shard. Then you split its zone across more shards.
- A hashed key gives perfect balance but no locality.

## 5. Part D — Partitioning in PostgreSQL ([evidence](evidence/d-postgres-partitioning.txt))

| Step | Result |
|---|---|
| D1 Range partitions by month | 1,000,000 trips into 13 monthly partitions + default (59k–85k rows each), loaded in 8.0 s. The PK becomes `(trip_id, requested_at)`, because a unique key must include the partition key. |
| D2 Planning-time pruning | June 2026 count → **only `trip_by_month_2026_06` is scanned** |
| D3 Run-time pruning | Prepared statement with a generic plan: **`Subplans Removed: 11`**; only the Sep and Oct 2026 partitions (plus the empty default) are scanned |
| D4 No partition key in the predicate | `rider_id = 25001` → every partition is visited (one local index probe each), the single-node equivalent of scatter-gather |
| D5 Archiving | `DETACH PARTITION` of Oct 2025 (59,588 rows) took **8.5 ms**, a metadata-only operation whose cost doesn't grow with data size. `DELETE` of the same rows took 16.7 ms here (small table, no indexes), but its cost grows with row count and leaves dead tuples for VACUUM. |

**Partitioning against sharding:**
- Partitioning splits one table *within one server*. It gives pruning, cheap archiving and smaller indexes, but doesn't add CPU, RAM or write capacity.
- Sharding spreads partitions *across servers* (Part C, or Citus for PostgreSQL).
- The same rule applies to both: queries that include the partition or shard key touch one piece; queries that don't touch all of them.

## 6. Part E — Cloud deployment

See [`cloud-deployment-design.md`](cloud-deployment-design.md). It covers:
- Multi-AZ managed PostgreSQL with a synchronous standby (RPO 0) and a reporting replica.
- MongoDB with a 3-AZ replica set per shard and zone sharding by city.
- CAP/PACELC choices per data type.
- NDPA data residency, security, monitoring and failure drills.
- What would differ from this local setup.

It is a design document; no cloud resources were provisioned.

## 7. Reproduce

```bash
. scripts/env.sh
./scripts/start-postgres.sh && ./scripts/start-mongo.sh     # Portfolio 1-4 servers must be running
portfolio-5-distributed-cloud/run_all.sh                     # ~4 minutes
./scripts/stop-all.sh                                         # stops every server started by the portfolio
```
