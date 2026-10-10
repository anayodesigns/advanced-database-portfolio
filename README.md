# MIT 8103 Advanced Database Systems — Practical Database Portfolio

**Student:** Obiianayo Anayo · **Session:** 2026/2027, First Semester · **Assessment:** Individual Practical Database Portfolio (40 marks)

**Repository (private):** https://github.com/anayodesigns/advanced-database-portfolio

## Selected case study: SwiftMove

**SwiftMove Technologies Ltd** is a *simulated* ride-hailing and on-demand parcel-delivery platform operating in **Lagos, Abuja, Port Harcourt, Ibadan and Kano**.

| | |
|---|---|
| **Nature of the business** | Riders book a car (Economy/Comfort), motorbike or van; a nearby approved driver accepts, completes the trip and is paid. The same flow delivers parcels. SwiftMove earns a 15–22% commission per trip. Payment is by in-app wallet, card or cash. |
| **Users of the database** | Riders (mobile app), drivers (driver app), the dispatch/matching service, finance (payouts, commission, reconciliation), operations and support staff, analysts |
| **Major data stored** | Cities and service zones; service categories and fare rules; riders; drivers; vehicles; trips and their status history; parcels; ratings; wallets; payments; an append-only money ledger; live driver locations and presence; rider referrals |
| **Key operations** | Request, match, start, complete or cancel a trip; compute fares; pay from a wallet (rider → driver + commission); rate; trip history and driver earnings; nearest-driver search; revenue reporting; wallet reconciliation |

The same case study, and largely the same data, is used in all five portfolio activities. MongoDB is loaded *from* the PostgreSQL database.

## Repository structure

```text
advanced-database-portfolio/
├── portfolio-1-database-design/          ER diagram, schema (13 tables, 36 CHECK, 19 FK), 1M-trip seed, normalisation
├── portfolio-2-query-optimisation/       8 queries, EXPLAIN ANALYZE before/after, indexes, materialized view, experiments
├── portfolio-3-transactions-concurrency/ commit/rollback/savepoint, 2-session anomaly demos, deadlock, pgbench stress
├── portfolio-4-nosql/                    MongoDB document, geospatial, key-value (TTL) and graph models
├── portfolio-5-distributed-cloud/        PG streaming replication + failover, Mongo replica set, sharded cluster, partitioning, cloud design
├── scripts/                              env.sh, start-postgres.sh, start-mongo.sh, stop-all.sh
├── AI-USE-DECLARATION.md
├── REFLECTION.md                         individual technical reflection (written by the student)
└── README.md
```

Each portfolio folder has its own `README.md` explaining what was done, how it was tested, the results, and how to reproduce it. Evidence (query plans, outputs, timelines, logs) is in each folder's `evidence/`, `plans/` or `results/`.

## Summary of results

| Portfolio | Highlights (all from committed evidence files) |
|---|---|
| **1 Design** | 13-table schema in 3NF/BCNF with surrogate and natural keys, 36 CHECK constraints (business rules such as "completed trip ⇒ fare and driver"), partial unique indexes; 1,000,000 trips, 3.8M status events, 1.5M ledger entries; all integrity checks pass, invalid writes rejected |
| **2 Optimisation** | Q1 rider history 37 → 0.11 ms (344×), Q3 dispatch 31.6 → 0.017 ms (1,861×), Q8 anti-join 306 → 9.6 ms; Q4 aggregate shown to be index-proof → materialized view (9,715×); Q5 bad join choice traced to `random_page_cost` and fixed; BRIN 40 kB against B-tree 21 MB |
| **3 Transactions** | Atomic 7-row wallet payment; constraint-triggered rollback; savepoints; lost update, non-repeatable read, write skew and deadlock reproduced with two live sessions and fixed; pgbench 1/4/16 clients with 0 lost money and 0 double payments; a lock hotspot found and removed (3.3× throughput) |
| **4 NoSQL** | 107,535 trip documents with JSON-Schema validation; COLLSCAN → IXSCAN (107,535 → 20 docs examined); nearest-driver `$geoNear` examining 16 of 5,000 drivers; TTL key-value presence; `$graphLookup` referral network; polyglot-persistence recommendation |
| **5 Distributed** | PostgreSQL primary + hot standby, sync vs async commit, crash + promotion in 121 ms with no committed data lost; MongoDB 3-node election in 11.1 s, writes refused without majority (CP); zone-sharded cluster with single-shard routing for city queries; partition pruning; cloud design (not deployed) |

## How to run everything

Tested on macOS 26 (Apple Silicon). PostgreSQL 17.6 (EDB binaries) and MongoDB 8.0.4 are installed as portable binaries under `~/.local/opt` (no admin rights needed); see `scripts/env.sh`.

```bash
. scripts/env.sh
./scripts/start-postgres.sh
psql -d postgres -c "CREATE DATABASE swiftmove"
psql -f portfolio-1-database-design/schema.sql -f portfolio-1-database-design/seed.sql   # ~1.5 min
psql -f portfolio-1-database-design/verify.sql
psql -f portfolio-2-query-optimisation/reset.sql && portfolio-2-query-optimisation/run.sh before
psql -f portfolio-2-query-optimisation/optimise.sql && portfolio-2-query-optimisation/run.sh after
psql -f portfolio-3-transactions-concurrency/setup.sql && portfolio-3-transactions-concurrency/run_all.sh
portfolio-4-nosql/run.sh
portfolio-5-distributed-cloud/run_all.sh
./scripts/stop-all.sh
```

## Honesty notes

- **SwiftMove is simulated.** All data is synthetic and generated deterministically (`setseed`). Zone names and coordinates are real Nigerian neighbourhoods.
- **Everything is local.** Distributed setups run as separate server processes on one machine. The cloud deployment (Portfolio 5, Part E) is a design document only, and no cloud resources were used.
- **Timings come from one laptop** and vary between runs. Where a figure in a README comes from an earlier run than the committed evidence, the README says so.
- AI assistance is declared in [`AI-USE-DECLARATION.md`](AI-USE-DECLARATION.md).

## References

- PostgreSQL Global Development Group. *PostgreSQL 17 Documentation*: chapters on Indexes, Performance Tips (`EXPLAIN`), Concurrency Control (MVCC, transaction isolation, explicit locking), Table Partitioning, High Availability, Load Balancing and Replication. https://www.postgresql.org/docs/17/
- MongoDB, Inc. *MongoDB 8.0 Manual*: Data Modeling, Schema Validation, Geospatial Queries, TTL Indexes, `$graphLookup`, Replication, Sharding (zones), Read/Write Concern. https://www.mongodb.com/docs/manual/
- Ports, D. R. K. and Grittner, K. (2012). *Serializable Snapshot Isolation in PostgreSQL*. Proceedings of the VLDB Endowment, 5(12).
- Berenson, H. et al. (1995). *A Critique of ANSI SQL Isolation Levels*. ACM SIGMOD.
- Kleppmann, M. (2017). *Designing Data-Intensive Applications*. O'Reilly. Replication, partitioning, transactions.
- Abadi, D. (2012). *Consistency Tradeoffs in Modern Distributed Database System Design* (PACELC). IEEE Computer, 45(2).
- Elmasri, R. and Navathe, S. B. *Fundamentals of Database Systems*, 7th ed. Pearson. ER modelling and normalisation.
- Apache Cassandra Documentation: Data Modeling. https://cassandra.apache.org/doc/latest/ (Portfolio 4 design only)
- Nigeria Data Protection Act, 2023 (Portfolio 5 design considerations).
- Tools: PostgreSQL 17.6 (EDB macOS binaries), pgbench, MongoDB 8.0.4 Community Server, mongosh 2.3.8, Git.
