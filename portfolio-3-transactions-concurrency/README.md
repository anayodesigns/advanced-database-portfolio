# Portfolio 3 — Transactions and Concurrency

Every demo runs against the SwiftMove database from Portfolios 1–2, using the money tables (`wallet`, `payment`, `wallet_ledger`) and trip dispatch. The concurrency demos open **two real database connections (A and B)** at the same time. Their output is merged into one timeline, with each line stamped by when it happened, so every interleaving is visible in the evidence.

## 1. Files

| File | Purpose |
|---|---|
| [`setup.sql`](setup.sql) | Cleans up a data-quality issue (section 4.5), creates `pay_trip()` and `topup()`, adds 20,000 unpaid demo trips |
| [`demos/01_commit.sql`](demos/01_commit.sql) | Atomic wallet payment, COMMIT, isolation of uncommitted work, idempotent retry |
| [`demos/02_rollback.sql`](demos/02_rollback.sql) | Automatic rollback on a constraint violation, explicit ROLLBACK, SAVEPOINT |
| [`demos/03_non_repeatable_read.sh`](demos/03_non_repeatable_read.sh) | READ COMMITTED vs REPEATABLE READ |
| [`demos/04_lost_update.sh`](demos/04_lost_update.sh) | Lost-update anomaly + 4 fixes |
| [`demos/05_write_skew.sh`](demos/05_write_skew.sh) | Write skew at RC / RR / SERIALIZABLE + constraint fix |
| [`demos/06_deadlock.sh`](demos/06_deadlock.sh) | Deadlock and ordered-locking fix |
| [`demos/07_stress_pgbench.sh`](demos/07_stress_pgbench.sh) | pgbench stress test with 1 / 4 / 16 clients + money invariants |
| [`demos/08_hotspot.sh`](demos/08_hotspot.sh) | Finding and removing a lock hotspot |
| [`demos/lib.sh`](demos/lib.sh) | Two-session harness (background `psql` sessions + merged timeline) |
| [`run_all.sh`](run_all.sh) | Runs everything and rewrites [`evidence/`](evidence) |

## 2. The payment transaction (`pay_trip`)

A wallet payment touches 7 rows: 1 payment, 3 wallet balances (rider, driver, platform) and 3 ledger entries. It must be **atomic**: all 7 changes or none. Design points:

1. **Lock the trip row first** (`SELECT … FOR UPDATE OF tr`). Two payment attempts for the same trip are serialised there.
2. **Idempotency.** If a successful payment already exists, return `already_paid`. A mobile app that retries after a timeout can never charge twice. The partial unique index `uq_payment_one_success` is a second safety net at the schema level.
3. **Lock the wallets in ascending `wallet_id` order.** Every transaction acquires locks in the same global order, so a circular wait (deadlock) is impossible. Demo 06 shows why this matters.
4. **Atomic arithmetic** (`balance = balance - fare`), never read-modify-write in the application (demo 04).
5. **Constraints as the last line of defence.** If the rider can't pay, `ck_wallet_balance` raises inside the function, and PostgreSQL rolls back the whole transaction, including the payment row already inserted (demo 02a).
6. `SET search_path = swiftmove` is pinned on the function. My first version didn't do this and failed when called from another session (see reflection notes in section 6). Pinning it is also the standard defence against search-path hijacking.

## 3. Results

| Demo | What happens | Evidence |
|---|---|---|
| **01 COMMIT** | Before COMMIT, session A sees its payment (`my_view_payments = 1`) while a second connection sees `0`. After COMMIT both see it. Ledger entries −1,600 / +1,280 / +320 sum to **0.00**. Retrying returns `already_paid`. | [`01-commit.txt`](evidence/01-commit.txt) |
| **02a automatic rollback** | Fare NGN 22,500 against a balance of 20,000. `ck_wallet_balance` fires and the transaction is aborted; later statements are rejected (`current transaction is aborted`). Payment and ledger counts are **unchanged** (929,509 / 1,526,653) and the balance is still 20,000. | [`02-rollback.txt`](evidence/02-rollback.txt) |
| **02b explicit ROLLBACK** | A payment wrongly marked `refunded` is back to `succeeded` after ROLLBACK. | same |
| **02c SAVEPOINT** | The trip is closed; an optional step fails with a PK violation; `ROLLBACK TO SAVEPOINT` discards only that step; COMMIT keeps the trip closure. | same |
| **03 READ COMMITTED** | A reads 5,011,000, B tops up and commits, A reads again: **5,012,000**. A *non-repeatable read*. | [`03-non-repeatable-read.txt`](evidence/03-non-repeatable-read.txt) |
| **03 REPEATABLE READ** | Same sequence; A's second read is **unchanged**, because A reads from the snapshot taken at its first query. | same |
| **04 lost update** | A and B both read the balance, then write `read - amount`. Final balance is **NGN 500 higher than the ledger**: B's debit was lost. | [`04-lost-update.txt`](evidence/04-lost-update.txt) |
| **04 Fix 1** atomic `UPDATE … balance - x` | B blocks on A's row lock for about 1.3 s (B's UPDATE is issued at t≈0.8 s and returns at t≈2.1 s), then re-evaluates against A's committed row. Difference **0.00**. | same |
| **04 Fix 2** `SELECT … FOR UPDATE` | B's read waits until A commits, then reads A's result. Difference **0.00**. | same |
| **04 Fix 3** REPEATABLE READ | A gets `ERROR: could not serialize access due to concurrent update` (SQLSTATE 40001); the app must retry. Difference **0.00**. | same |
| **04 Fix 4** optimistic locking | A's `UPDATE … WHERE version = :v` affects **0 rows** (conflict detected); A retries with fresh data and succeeds. No lock is held while the app "thinks". Difference **0.00**. | same |
| **05 write skew** RC and RR | Both dispatchers see 0 active trips, each assigns the driver to a different trip, both commit: **2 active trips, rule violated**, at *both* levels. | [`05-write-skew.txt`](evidence/05-write-skew.txt) |
| **05 SERIALIZABLE** | B fails: `could not serialize access due to read/write dependencies among transactions`. Rule holds. | same |
| **05 constraint fix** | Partial unique index `uq_trip_one_active_per_driver`. At plain READ COMMITTED, B waits for A, then fails with `duplicate key value violates unique constraint`. Rule holds. | same |
| **06 deadlock** | A locks wallet 49981 then wants 49982; B does the opposite. After `deadlock_timeout` (1 s) PostgreSQL reports the cycle (`Process X waits for ShareLock … blocked by process Y`) and aborts A; B commits. | [`06-deadlock.txt`](evidence/06-deadlock.txt) |
| **06 ordered locking** | Both lock `ORDER BY wallet_id FOR UPDATE` first. B just waits, and both commit. No deadlock. | same |
| **07 stress test** | 20,000 payment attempts, 1 / 4 / 16 clients, **0 failed transactions, 0 deadlocks**. After every run: total money unchanged (NGN 2,084,747,690.00), **0** wallets mismatching the ledger, **0** trips paid twice, **0** negative rider balances. | [`07-stress-pgbench.txt`](evidence/07-stress-pgbench.txt) |
| **08 hotspot** | Moving the platform's commission credit to a settlement job takes 16 clients from **5,127 to 16,707 payments/s (3.3×)**; latency 1.93 → 0.57 ms. (Earlier run: 5,474 → 18,712.) Invariants still hold after settlement. | [`08-hotspot.txt`](evidence/08-hotspot.txt) |

## 4. Analysis

### 4.1 Isolation levels in PostgreSQL

PostgreSQL uses **MVCC**: each transaction reads a snapshot, and readers never block writers. Isolation level decides *when* the snapshot is taken and *what is checked at commit*:

| Anomaly | READ COMMITTED (default) | REPEATABLE READ (snapshot isolation) | SERIALIZABLE (SSI) |
|---|---|---|---|
| Dirty read | Impossible (demo 01: uncommitted payment invisible) | Impossible | Impossible |
| Non-repeatable read | **Possible** (demo 03) | Prevented (demo 03) | Prevented |
| Lost update (read-modify-write) | **Possible** (demo 04) | Prevented: 40001 error (demo 04 fix 3) | Prevented |
| Write skew | **Possible** (demo 05) | **Possible** (demo 05) | Prevented: 40001 error (demo 05) |

Key observations:
- **REPEATABLE READ isn't enough for multi-row rules.** In demo 05 the two transactions write *different* rows, so no write–write conflict exists. Snapshot isolation only detects write–write conflicts. SERIALIZABLE (Serializable Snapshot Isolation) also tracks read–write dependencies, which is how it caught the write skew.
- **Higher isolation shifts work to the application.** REPEATABLE READ and SERIALIZABLE don't wait; they *fail* (SQLSTATE 40001), and the client must retry the whole transaction. Any code that uses them needs a retry loop.
- **The most robust fix was a constraint, not an isolation level.** The partial unique index enforces "one active trip per driver" for every application, at every isolation level, and costs one tiny index (only active trips are in it). SERIALIZABLE is a good general safety net, but declarative constraints come first wherever the rule can be expressed as one.

### 4.2 Pessimistic vs optimistic concurrency control

| | Pessimistic (`FOR UPDATE`, atomic UPDATE) | Optimistic (version column) |
|---|---|---|
| Conflict handling | Second transaction **waits** | Second transaction **detects** and retries |
| Holds locks while app thinks | Yes | No |
| Best when | Conflicts are frequent and short (wallet debits) | Conflicts are rare, or "think time" is long (e.g. a support agent editing a profile form) |
| SwiftMove choice | `pay_trip()` uses row locks: money must never fail spuriously | `wallet.version` is kept for admin/UI edits |

### 4.3 Deadlocks

PostgreSQL doesn't prevent deadlocks, it **detects** them. After `deadlock_timeout` it searches the wait-for graph, finds the cycle and aborts one victim (A in demo 06, `pg_stat_database.deadlocks = 1`). Detection is a fallback; the design goal is that deadlocks *cannot* happen. Acquiring row locks in one global order (ascending `wallet_id`) removes the circular wait condition entirely. `pay_trip()` does exactly this, and the stress test recorded **0 deadlocks** across about 100,000 payment transactions run concurrently (demos 07 and 08).

### 4.4 Throughput and the platform-wallet hotspot

| Clients | Real payments/s | Avg latency |
|---:|---:|---:|
| 1 | 4,255 | 0.147 ms |
| 4 | 5,982 | 0.415 ms |
| 16 | 5,672 | 1.750 ms |

(Values from the final run in `evidence/07-stress-pgbench.txt`; two earlier runs gave the same shape: 4,135 / 6,176 / 5,817 payments/s.)

Throughput **stops scaling after 4 clients**, while latency grows about 4× from 4 to 16 clients (0.415 → 1.750 ms): a sign of queueing. Every payment locks and updates **one shared row**, the platform wallet (commission). So all payments serialise on it, however many rider and driver wallets exist.

Demo 08 tested this hypothesis. Writing the commission to the ledger only, and rolling it into the platform balance with a periodic `settle_platform()` job, gave **3.3× more throughput** at 16 clients (5,127 → 16,707 payments/s), with all invariants intact after settlement. The trade-off: the platform's balance is stale between settlements. That's acceptable for the company's own revenue account, but **not** for rider or driver balances, which must stay exact per payment. Other production options include splitting the platform account into N sub-accounts (chosen by `payment_id % N`), or a separate commission service.

*Measurement note:* the pool has 19,999 trips and attempts pick trips at random. About 37% of attempts hit an already-paid trip, which matches the expected 1 − e⁻¹ ≈ 63% coverage. "Real payments/s" counts only trips actually paid, measured from the database, not pgbench's raw TPS. My first version of the test ran the 1-client and 16-client runs back to back on the same pool. The 16-client run then mostly hit the cheap `already_paid` path and showed an inflated 69k TPS. I discarded that and reset the pool before each run.

### 4.5 A real concurrency bug found in the data

While preparing demo 05, I found that **9 drivers in the seed data had two active trips at once**. The schema never enforced "one active trip per driver"; my generator assigned drivers randomly, much like two dispatchers racing in demo 05. `setup.sql` cancels the older duplicate of each pair, and demo 05 adds `uq_trip_one_active_per_driver`, which stays in the database as a permanent constraint. The lesson: application-level checks ("count active trips, then assign") are exactly the pattern that write skew breaks.

## 5. ACID mapping

| Property | Where it is demonstrated |
|---|---|
| **Atomicity** | 02a: payment insert undone when the balance update fails; 01: 7 rows change together |
| **Consistency** | CHECK, FK and unique constraints (02a, 05); ledger = balance invariant after every demo and stress run |
| **Isolation** | 01 (uncommitted work invisible), 03, 04, 05 (anomalies and how each level handles them) |
| **Durability** | COMMIT returns only after the WAL is flushed (`synchronous_commit = on`, default); the committed payment is visible to new connections (01). Portfolio 5 extends this to replicas. |

## 6. Notes on problems hit along the way

- **Functions failing in other sessions.** The background psql sessions don't have `search_path = swiftmove`, and `topup()` couldn't find `wallet`. Fixed by pinning the search path on the functions (section 2).
- **Unfair benchmark.** The first pgbench design was invalid (section 4.4) and was redone.
- **Timestamps in the evidence.** psql output had to be timestamped as it appeared. `lib.sh` pipes each session through Perl with `$| = 1` (unbuffered), and I checked with a flush test before trusting the timelines.

## 7. Reproduce

```bash
. scripts/env.sh
psql -f portfolio-3-transactions-concurrency/setup.sql      # once
portfolio-3-transactions-concurrency/run_all.sh             # ~1 minute, rewrites evidence/
```

Demos 04 and 06 change demo wallet balances outside the ledger on purpose, and restore them from the ledger after each round.
