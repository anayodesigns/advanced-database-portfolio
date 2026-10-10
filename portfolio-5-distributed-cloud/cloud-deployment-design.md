# SwiftMove — Cloud Deployment Design (Part E)

> **Status: design only.** Nothing in this document was deployed to a cloud provider; no cloud account was used for this portfolio. Parts A–D were implemented and tested **locally** as multi-process clusters on one machine. This document maps that tested architecture onto a production cloud deployment and states the trade-offs.

## 1. Requirements that drive the design

| Requirement | Source in the portfolio | Target |
|---|---|---|
| Money must never be lost or double-spent | Portfolio 3 invariants | **RPO = 0** for wallet/ledger data |
| Riders and drivers must keep booking during a server failure | Part A failover, Part B election | **RTO < 1 min** for the database tier |
| Dispatch reads (nearest driver, open requests) must be fast | Portfolio 2 Q3, Portfolio 4 geo search | < 50 ms p99 within a city |
| Reporting must not slow down the booking path | Portfolio 2 Q4 (400 ms aggregate) | Analytics on replicas only |
| Personal data of Nigerian users | Nigeria Data Protection Act 2023 (NDPA) | Keep primary data in-region; encrypt at rest and in transit; documented cross-border transfers |
| Growth beyond one server | Part C sharding | Scale writes horizontally by city |

## 2. Target architecture

```text
                     Riders / Drivers (mobile apps)
                                 │ HTTPS
                     ┌───────────▼────────────┐
                     │ API + dispatch service │  (containers, autoscaled, 3 AZs)
                     └──┬─────────┬────────┬──┘
          money, users  │         │ trips, │ presence
          (ACID)        │         │ geo    │ (TTL / key-value)
   ┌────────────────────▼──┐  ┌───▼────────▼──────────────────────┐
   │ PostgreSQL (managed)  │  │ MongoDB (managed, sharded)        │
   │ primary  AZ-a         │  │ shard LAGOS: 3-node replica set   │
   │ sync standby AZ-b     │  │ shard REST:  3-node replica set   │
   │ read replica AZ-c ────┼─▶│ config servers (3) + mongos       │
   │  (reporting, MVs)     │  │ members spread over AZ-a/b/c      │
   └──────────┬────────────┘  └───────────────────────────────────┘
              │ WAL archive + daily snapshots (point-in-time recovery, 35 days)
              ▼
        object storage (encrypted), cross-region copy for disaster recovery
```

**Region.** An African region close to Nigerian users for latency and data-residency reasons (e.g. AWS `af-south-1` Cape Town, or a Nigerian/West-African provider or co-location if regulators require in-country hosting). The exact choice needs a legal review under the NDPA and isn't decided here.

## 3. PostgreSQL tier (system of record: users, wallets, payments, ledger)

| Decision | Tested locally in | Production setting |
|---|---|---|
| Streaming replication, primary + standby in **different availability zones** | Part A (A1–A2) | Managed Multi-AZ PostgreSQL (e.g. Amazon RDS / Aurora PostgreSQL, Google Cloud SQL HA, Azure Flexible Server zone-redundant HA) |
| **Synchronous** commit to one standby for RPO = 0 | Part A6: synchronous commit cut local throughput by 18% (50% in an earlier run) | Accept the cost for the money tables. Across AZs expect +1–2 ms per commit. Portfolio 3's hotspot fix (deferred commission) recovers far more than that. |
| Automatic failover | Part A8: promotion in 121 ms, committed payment survived | Managed failover (typically under a minute including DNS/endpoint switch). Clients must retry on connection loss, and `pay_trip()` is idempotent, so retries are safe. |
| Read replica for reporting | Part A5 (Q4b served by the standby) | Dashboards, materialized views and exports run on an async replica, so the 400 ms aggregates never touch the primary |
| Partitioning of `trip` by month | Part D | Old months detached and moved to cheap storage; recent months stay hot |
| Planner settings for SSD storage | Portfolio 2 E7 | `random_page_cost = 1.1`, `work_mem` sized for reporting replicas |
| Backups | — | Continuous WAL archiving + snapshots, PITR window 35 days, restore drill each quarter |

## 4. MongoDB tier (trips documents, dispatch geo search, presence)

| Decision | Tested locally in | Production setting |
|---|---|---|
| Every shard is a **3-member replica set across 3 AZs** | Part B: election after 11.1 s, majority write survived, no writes without majority | Managed MongoDB (e.g. MongoDB Atlas) M-tier cluster, one member per AZ |
| Writes with `w: "majority"`, reads `readConcern: "majority"` for trip state | Part B3: majority writes about 6.8 ms against 0.3 ms locally | Trip status changes use majority; telemetry-like writes (heartbeats) use `w: 1` |
| **Zone sharding by city** (`{city, _id}`) | Part C: Lagos queries hit one shard, data split 50/50 | Start with 2 zones (Lagos / rest of Nigeria); add a zone per new city or country. This also supports data residency if SwiftMove expands abroad (e.g. a Ghana zone on in-country nodes). |
| Hashed key rejected for `trips` | Part C5: even spread, but every city query hits all shards | Use hashed keys only for collections without a locality need |
| Lower election timeout? | — | Keep the 10 s default. Shorter timeouts cause false elections on cross-AZ network blips. |
| Presence data | Portfolio 4 demo 7 | Move to managed Redis (TTL keys) at scale; MongoDB TTL is fine at launch |

## 5. Consistency and availability (CAP / PACELC)

| Data | During a network partition (CAP) | Normal operation (PACELC: latency vs consistency) |
|---|---|---|
| Wallets, payments, ledger (PostgreSQL) | **Consistency.** A primary cut off from its synchronous standby stops confirming commits, rather than risk losing money. | Consistency. Pay the sync-commit latency. |
| Trip documents (MongoDB) | **Consistency for writes.** No primary without a majority (Part B5). Reads from secondaries stay **available**, possibly stale. | Majority writes for state changes; secondary reads allowed for history screens |
| Driver presence, GPS pings | **Availability.** Losing a few seconds of heartbeats is harmless. | Latency first: `w: 1`, TTL expiry |
| Reporting | **Availability.** Async replicas can lag by seconds (Part A7: 5.6–7.3 MB of WAL lag under bulk load, caught up within seconds). | Latency of the booking path is protected by isolating reporting |

## 6. Security

- TLS everywhere (client to database, and replication traffic). Private subnets only; no public database endpoints.
- Encryption at rest with provider-managed keys (KMS). Separate keys per environment.
- Least-privilege roles. For example, the API role can execute `pay_trip()` but can't `UPDATE wallet` directly (`SECURITY DEFINER` function plus a revoked table grant). The pinned `search_path` from Portfolio 3 matters here.
- Audit logging on the money tables. The append-only `wallet_ledger` is already an audit trail.
- Personal data minimisation in MongoDB snapshots (rider phone could be masked in documents used for analytics).

## 7. Operating the system

| Concern | Plan |
|---|---|
| Monitoring | Replication lag (`pg_stat_replication`, `rs.printSecondaryReplicationInfo`), lock waits, deadlocks (`pg_stat_database.deadlocks`), slow queries (`pg_stat_statements`), chunk balance per shard |
| Alerting | Lag > 5 s on the sync standby; no MongoDB primary for > 15 s; ledger/balance reconciliation (Portfolio 1 `verify.sql` check 1) ≠ 0, which is a P1 incident |
| Failure drills | Quarterly: kill the primary in staging (as in Parts A8 and B4) and measure the real RTO |
| Schema changes | Expand-and-contract migrations; MongoDB validator updated in the same release as the app |
| Cost control | Reporting replica sized smaller; old trip partitions archived to object storage (Part D5); MongoDB tiered storage for trips older than 12 months |

## 8. What would change from the local setup

| Local (this portfolio) | Production |
|---|---|
| All nodes on one laptop, one disk | Nodes in 3 availability zones; network latency adds to sync commits and majority writes |
| Single-member shard replica sets and config server (Part C) | 3-member replica sets for every shard and the config servers |
| `trust` authentication | SCRAM / IAM authentication, TLS certificates |
| Manual promotion (`pg_ctl promote`) | Managed or orchestrated failover (e.g. Patroni if self-hosted) with fencing of the old primary |
| Restoring the old primary by restarting it (Part A9) | The old primary is rebuilt from the new one (`pg_rewind` or a fresh base backup) so two primaries can never accept writes (split brain) |
