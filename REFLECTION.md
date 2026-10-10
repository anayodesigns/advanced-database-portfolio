# Individual Technical Reflection

> **This section must be written by the student, in their own words.** The brief (sections 8-IV and 12-XI) asks for *your* design choices, challenges and lessons, and you may be asked to explain them in a verification discussion. Below are prompts and a factual list of problems that came up while building the portfolio, which you can draw on. Replace this whole file with your own reflection (about ½–1 page).

## Prompts

1. **Design choices.** Which decision in the SwiftMove schema would you defend first, and why? (e.g. storing `fare_amount` but *not* the average rating; a ledger plus a stored balance; separate `parcel` table vs MongoDB's embedded `parcel`)
2. **What surprised you in the performance results?** (e.g. an index made Q4 no faster; the planner chose a slower join for Q5 until `random_page_cost` was changed; a 40 kB BRIN index matched a 21 MB B-tree)
3. **Concurrency.** Which anomaly would be most damaging for a real payments company, and which fix would you choose in production? Why is a constraint sometimes better than a higher isolation level?
4. **Relational vs NoSQL.** Where would you *not* use MongoDB for SwiftMove, and why?
5. **Distributed trade-offs.** What did killing the primary, or losing the majority, teach you about CAP in practice? Would you pay the synchronous-commit cost for wallets?
6. **Use of AI.** What did you learn from reviewing AI-generated work? What would you do differently?
7. **Limitations and next steps.** (e.g. synthetic data, single machine, no real cloud deployment, no Cassandra/Redis implementation)

## Problems that actually occurred (facts you can refer to)

| Where | Problem | How it was resolved |
|---|---|---|
| Environment | No Homebrew or admin rights to install databases | Portable EDB PostgreSQL and MongoDB binaries in the home folder |
| P1 seed | Inactive-vehicle insert collided with explicit IDs | Moved the identity sequence past the existing IDs (`setval`) |
| P1/P3 | 9 drivers had two active trips at once; the schema never enforced the rule | Cleaned up, then added the partial unique index `uq_trip_one_active_per_driver` (demo 05) |
| P2 | Q4 got no faster with indexes | Plan showed a 473k-row aggregate with a disk-spilling sort → materialized view |
| P2 | Planner picked a hash join for Q5 that was slower than a nested loop | `random_page_cost` (default 4, for spinning disks) vs SSD (1.1) |
| P3 | Functions failed when called from another session | Pinned `SET search_path` on the functions |
| P3 | First pgbench result (69k TPS) was invalid: most trips were already paid | Reset the pool before each run; count only real payments |
| P3 | Throughput stopped scaling beyond 4 clients | Every payment locked the single platform wallet row; deferring the commission gave 3.3× |
| P4 | `$jsonSchema` has no `if/then` | Combined `$jsonSchema` with a `$or` query clause |
| P4 | TTL demo expired *all* keys | Live drivers must keep sending heartbeats; the demo now simulates them |
| P5 | Replication probe loop hung | `psql -At` also printed `INSERT 0 1`; fixed with `-q` and a loop timeout |
| P5 | `city = "Lagos"` was sent to both shards | Inclusive query bound touched the next chunk; the zone now ends at `"Lagos\u0000"` |
