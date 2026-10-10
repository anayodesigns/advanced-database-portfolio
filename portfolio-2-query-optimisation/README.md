# Portfolio 2 — Query Processing and Optimisation

All measurements are on the Portfolio 1 SwiftMove database: 1,000,000 trips, about 1.07 GB.

**Environment.** PostgreSQL 17.6, MacBook (Apple Silicon, SSD), default configuration: `shared_buffers=128MB`, `work_mem=4MB`, `random_page_cost=4`.

**Method.** Each query runs **5 times** with `EXPLAIN (ANALYZE, BUFFERS)`. The table reports the **median**, and the 5th (warm-cache) plan is saved.

## 1. Files

| File | Purpose |
|---|---|
| [`queries/`](queries) | The 8 business queries (Q1–Q8) |
| [`queries-after/`](queries-after) | Q4b (served from a materialized view) and Q5b (rewritten) |
| [`reset.sql`](reset.sql) | Drops all optimisation objects, back to the Portfolio 1 baseline |
| [`optimise.sql`](optimise.sql) | Creates the indexes and materialized view, then VACUUM ANALYZE |
| [`run.sh`](run.sh) | `./run.sh before` / `./run.sh after`: runs the queries, saves plans and timings |
| [`experiments.sh`](experiments.sh) | Extra experiments E1–E7 (work_mem, join choice, BRIN vs B-tree, planner costs) |
| [`plans/before/`](plans/before), [`plans/after/`](plans/after) | Full execution plans |
| [`results/`](results) | Query outputs, `timings-*.tsv` (all 5 runs), `optimise-output.txt`, `experiments.txt` |

## 2. Results

| # | Query (business use) | Before: plan | Before (ms) | Optimisation | After: plan | After (ms) | Speed-up |
|---|---|---|---:|---|---|---:|---:|
| Q1 | Rider's last 20 trips | Parallel Seq Scan + top-N sort, 23,996 pages | 37.17 | B-tree `(rider_id, requested_at DESC)` | Index Scan, stops after 20 rows, 61 pages | 0.108 | **344×** |
| Q2 | Driver's daily earnings, 30 days | Parallel Seq Scan | 32.15 | Partial **covering** index `(driver_id, completed_at) INCLUDE (fare_amount) WHERE status='completed'` | **Index Only Scan**, `Heap Fetches: 0`, 10 pages | 0.158 | **203×** |
| Q3 | Dispatcher: open requests in a zone | Parallel Seq Scan, 999,999 rows removed | 31.63 | **Partial** index `WHERE status='requested'` (32 kB) | Index Scan, 4 pages | 0.017 | **1,861×** |
| Q4 | Finance: revenue per city per month | Seq Scan + 3 hash joins + **external merge sort (17 MB on disk)** | 398.34 | Indexes don't help; **materialized view** (Q4b) | Q4: unchanged plan / Q4b: Index Scan on 35-row MV | 403.22 / **0.041** | 1× / **9,715×** |
| Q5 | Top-rated Lagos drivers, 30 days | Parallel Seq Scan on trip + rating | 55.28 | Partial covering index on `rating(created_at)`; query rewrite (Q5b) | Rating: Index Only Scan, trip: still Seq Scan / Q5b: BRIN bitmap scan | 42.88 / **15.42** | 1.3× / **3.6×** |
| Q6 | Support: rider by email, any case | Seq Scan on 50k riders (UNIQUE(email) unusable) | 4.81 | **Expression** index `lower(email)` | Index Scan, 4 pages | 0.015 | **320×** |
| Q7 | Requests per hour on one day | Parallel Seq Scan | 30.81 | **BRIN** on `requested_at` (40 kB) | Bitmap Heap Scan via BRIN, 173 pages | 1.09 | **28×** |
| Q8 | Lapsed Abuja riders with balance (NOT EXISTS) | Hash Anti Join over 165k trips, re-scanned 5,520× from Materialize, 4.4M rows filtered | 305.60 | Reuses Q1's index | **Nested Loop Anti Join** + Index Only Scan per rider (371 probes) | 9.63 | **32×** |

The optimised queries return **identical results**. Q5 and Q5b, and Q4 and Q4b, were compared with `diff`.

## 3. Query-by-query analysis

**Q1 — composite index whose order matches the `ORDER BY`.** Without an index, PostgreSQL reads all 23,996 pages of `trip` (about 190 MB) with two parallel workers to find 1,145 trips by one rider, then sorts them. The index on `(rider_id, requested_at DESC)` puts each rider's trips together, newest first. The executor therefore reads the first 20 index entries and stops: the `Limit` node never asks for more. The two zone joins become nested loops over `zone_pkey`, with a **Memoize** node caching repeated zone ids across the 20 rows. Buffers dropped from 23,996 to 61.

**Q2 — partial and covering index → index-only scan.** The query filters on `status = 'completed'` and reads only `fare_amount`.
- *Partial* (`WHERE status='completed'`): the 10% of trips that never complete aren't indexed, so the index is smaller.
- *Covering* (`INCLUDE (fare_amount)`): the index holds everything the query needs, so the table heap isn't visited (`Heap Fetches: 0`).
- Index-only scans rely on the **visibility map**. That is why `optimise.sql` runs `VACUUM ANALYZE`; without it, PostgreSQL would still have to check heap pages for visibility.

**Q3 — partial index for a "hot" subset.** The dispatcher polls every few seconds for the roughly 300 trips in `requested` status out of 1M. A full index on `status` would be 21 MB and mostly useless. The partial index is **32 kB**, fits in a single page per zone, and makes the poll 1,861× cheaper. It also costs almost nothing on writes: only rows entering or leaving `requested` touch it.

**Q4 — when indexes can't help.** The query aggregates 473,220 completed trips (47% of the table) over six months. At that selectivity a sequential scan is the cheapest access path. The before and after plans are **identical**, and the 1% time difference is run-to-run noise.
- The expensive step is the sort before `GroupAggregate`: `Sort Method: external merge Disk: 17152kB`, because 473k rows don't fit in `work_mem = 4MB`.
- Experiment E1: `work_mem = 64MB` turns it into an in-memory quicksort (34.9 MB). The query only gets about 23% faster (503 → 386 ms), so it is CPU-bound, not I/O-bound.
- The right answer is to stop recomputing it. `mv_city_monthly_revenue` pre-aggregates to 35 rows. The dashboard then runs in **0.041 ms**, and `REFRESH MATERIALIZED VIEW CONCURRENTLY` (435–549 ms, E6) runs every 15 minutes.
- **Trade-off:** dashboard numbers can be up to 15 minutes stale. That's acceptable for finance reporting, but not for wallet balances. The unique index on the view is required for a concurrent refresh, which doesn't block readers.

**Q5 — reading the plan to find the real bottleneck.**
- The new rating index *is* used: Index Only Scan, 51,829 ratings. The cost moved to the join. The planner hash-joins those ratings against a **parallel sequential scan of all 1M trips**, estimating that 51,829 random primary-key lookups would cost more.
- **E2:** forcing a nested loop gives 26 ms against 40 ms. The planner's choice was wrong for this machine.
- **E7:** the cause is the cost model. `random_page_cost = 4` assumes spinning disks. With the SSD-appropriate value `1.1`, the planner chooses the nested loop on its own (22 ms). In production I would set `random_page_cost = 1.1` for an SSD-backed server.
- **Q5b:** I used a business rule. Ratings are only accepted within 24 hours of a trip, so the trip side can carry the same time window (+1 day). Because `trip` is physically ordered by `requested_at` (correlation = 1.0, E5), the 40 kB BRIN index skips about 91% of the table. Result: **15.4 ms (3.6×)**, with output identical to Q5. This is only valid if the rule is enforced, by the app or a trigger. Otherwise the rewrite could silently drop late ratings.

**Q6 — expression index.** `UNIQUE(email)` builds a B-tree on `email`, but the predicate is on `lower(email)`. A B-tree can only serve the exact expression it indexes, so PostgreSQL scanned all 50,000 riders. The expression index `rider (lower(email))` matches the predicate: 4 buffers, 0.015 ms. A good follow-up would be making it `UNIQUE`, so two emails differing only in case are rejected (or using the `citext` type).

**Q7 — BRIN against B-tree.** Trips are appended in time order, so `requested_at` correlates perfectly with physical position (E5: 1.0000). A BRIN index stores just the min and max per block range: **40 kB, against 21 MB** for the equivalent B-tree (E4, about 500× smaller).
- For a one-day range, BRIN returns a few block ranges. The bitmap heap scan rechecks them (`Rows Removed by Index Recheck: 3990`) and still answers in 1.1 ms.
- The B-tree's index-only scan is about as fast (2.2 ms). For append-only time series, BRIN gives almost the same speed at a tiny fraction of the size and write cost.
- BRIN would be useless on `rider_id` or `driver_id` (correlation ≈ 0).

**Q8 — anti-join strategy.** Without an index on `trip.rider_id`, the planner builds a hash anti-join over 165k recent trips. It then materialises the result and re-scans it 5,520 times inside a nested loop: 4.4 million rows discarded by a join filter. With Q1's `(rider_id, requested_at)` index, it switches to a **Nested Loop Anti Join**. For each of the 371 candidate riders, one index-only probe checks "any trip since 11 Aug?" and stops at the first hit. 305 → 9.6 ms. One well-chosen composite index served two different queries.

## 4. Concepts demonstrated

- **Cost-based optimisation and statistics.** Plan choice comes from estimated row counts (`ANALYZE`) and cost parameters: estimated rows ≈ actual in every plan here. E7 shows that the cost constants (`random_page_cost`) need to match the hardware.
- **Access paths:** sequential scan, parallel sequential scan (2 workers), index scan, index-only scan, bitmap heap scan.
- **Join algorithms:** hash join (Q4, Q5), nested loop with index lookups (Q1, Q8, Q5 at rpc 1.1), hash and nested-loop **anti-joins** for `NOT EXISTS` (Q8).
- **Index types:** composite B-tree, partial, covering (`INCLUDE`), expression, BRIN. Plus a materialized view as pre-computed query results.
- **Memory and spilling:** external merge sort against quicksort, depending on `work_mem` (E1).
- **Query rewriting** using a business constraint (Q5b), checked by comparing results.

## 5. Costs of the optimisation

Indexes aren't free (sizes from [`results/optimise-output.txt`](results/optimise-output.txt)):

| Object | Size | Write cost |
|---|---:|---|
| `ix_trip_driver_completed` (partial, covering) | 35 MB | Updated on each trip completion |
| `ix_trip_rider_requested` | 30 MB | Every new trip |
| `ix_rating_recent_r2d` | 24 MB | Every rider→driver rating |
| `ix_trip_driver` | 6.9 MB | Every matched trip |
| `ix_rider_email_lower` | 2.6 MB | New riders / email changes only |
| `ix_trip_requested_brin` | **40 kB** | Almost none |
| `ix_trip_open_requests` | **32 kB** | Only rows entering or leaving `requested` |
| `mv_city_monthly_revenue` | 35 rows | Refresh every 15 min (about 0.5 s) |

Altogether about 98 MB of extra index space (about 9% of the database), and each new trip now updates 3–4 extra indexes. That's a sensible trade for a read-heavy app, where trip history and earnings screens are read far more often than trips are written. I did **not** add an index for Q4: it would add write cost and give no read benefit.

## 6. Limitations

- Timings are warm-cache medians on a laptop. Absolute numbers will differ on a server, but the plan shapes and buffer counts are what the analysis relies on.
- PostgreSQL here is the x86-64 EDB build running under Rosetta 2, which adds some CPU overhead equally to every run.
- The data is synthetic (Portfolio 1). Its distributions (rider skew, time-ordered inserts) are realistic, but real data would have more variation.

## 7. Reproduce

```bash
. scripts/env.sh
psql -f portfolio-2-query-optimisation/reset.sql
portfolio-2-query-optimisation/run.sh before
psql -f portfolio-2-query-optimisation/optimise.sql
portfolio-2-query-optimisation/run.sh after
portfolio-2-query-optimisation/experiments.sh
```
