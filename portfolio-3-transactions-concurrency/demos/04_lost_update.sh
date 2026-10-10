#!/bin/bash
# Demo 04 — Lost update: two payments debit the same wallet with application-style
# read-modify-write. Then four fixes. Wallet of rider 49970 (wallet 49971) is used and
# reconciled against the ledger after every round.
cd "$(dirname "$0")"; . ./lib.sh
OUT="$EVID/04-lost-update.txt"; : > "$OUT"
W=49971
reconcile() { psql -X -At -c "SELECT format('RESULT  balance=%s  ledger_sum=%s  difference=%s', w.balance, s, w.balance - s)
  FROM swiftmove.wallet w, LATERAL (SELECT sum(amount) s FROM swiftmove.wallet_ledger WHERE wallet_id = w.wallet_id) l WHERE w.wallet_id = $W" | tee -a "$OUT"
  psql -X -q -c "UPDATE swiftmove.wallet SET balance = (SELECT sum(amount) FROM swiftmove.wallet_ledger WHERE wallet_id = $W) WHERE wallet_id = $W"; echo | tee -a "$OUT"; }

# ---------- Round 1: the anomaly ----------
cat > "$TMP/a.sql" <<SQL
-- A: pay NGN 1,000 trip. Reads balance, "thinks" for 2 s, writes balance - 1000.
BEGIN;
SELECT balance AS a_read FROM swiftmove.wallet WHERE wallet_id = $W \gset
SELECT pg_sleep(2) \g /dev/null
UPDATE swiftmove.wallet SET balance = :a_read - 1000 WHERE wallet_id = $W;
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -1000);
COMMIT;
SQL
cat > "$TMP/b.sql" <<SQL
-- B: pay NGN 500 trip, same wallet, same pattern, finishes first.
BEGIN;
SELECT balance AS b_read FROM swiftmove.wallet WHERE wallet_id = $W \gset
UPDATE swiftmove.wallet SET balance = :b_read - 500 WHERE wallet_id = $W;
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -500);
COMMIT;
SQL
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.7
timeline "Round 1 — ANOMALY: read-modify-write under READ COMMITTED (expect B's 500 debit to be lost)" "$OUT"; reconcile

# ---------- Fix 1: atomic UPDATE (let the database do the arithmetic under its row lock) ----------
cat > "$TMP/a.sql" <<SQL
BEGIN;
UPDATE swiftmove.wallet SET balance = balance - 1000 WHERE wallet_id = $W RETURNING balance AS a_new;
SELECT pg_sleep(2) \g /dev/null
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -1000);
COMMIT;
SQL
cat > "$TMP/b.sql" <<SQL
BEGIN;
-- B blocks here on A's row lock, then re-evaluates on the committed row (EvalPlanQual)
UPDATE swiftmove.wallet SET balance = balance - 500 WHERE wallet_id = $W RETURNING balance AS b_new;
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -500);
COMMIT;
SQL
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.7
timeline "Fix 1 — atomic UPDATE balance = balance - x (B waits for A, nothing lost)" "$OUT"; reconcile

# ---------- Fix 2: pessimistic locking, SELECT ... FOR UPDATE ----------
cat > "$TMP/a.sql" <<SQL
BEGIN;
SELECT balance AS a_read FROM swiftmove.wallet WHERE wallet_id = $W FOR UPDATE \gset
SELECT pg_sleep(2) \g /dev/null
UPDATE swiftmove.wallet SET balance = :a_read - 1000 WHERE wallet_id = $W;
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -1000);
COMMIT;
SQL
cat > "$TMP/b.sql" <<SQL
BEGIN;
-- B's SELECT ... FOR UPDATE waits until A commits, then reads A's result
SELECT balance AS b_read FROM swiftmove.wallet WHERE wallet_id = $W FOR UPDATE \gset
\echo B read :b_read
UPDATE swiftmove.wallet SET balance = :b_read - 500 WHERE wallet_id = $W;
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -500);
COMMIT;
SQL
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.7
timeline "Fix 2 — SELECT ... FOR UPDATE (pessimistic row lock)" "$OUT"; reconcile

# ---------- Fix 3: REPEATABLE READ detects the conflict ----------
cat > "$TMP/a.sql" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS a_read FROM swiftmove.wallet WHERE wallet_id = $W \gset
SELECT pg_sleep(2) \g /dev/null
-- B changed this row after A's snapshot was taken -> serialization failure
UPDATE swiftmove.wallet SET balance = :a_read - 1000 WHERE wallet_id = $W;
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -1000);
COMMIT;
SQL
cat > "$TMP/b.sql" <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS b_read FROM swiftmove.wallet WHERE wallet_id = $W \gset
UPDATE swiftmove.wallet SET balance = :b_read - 500 WHERE wallet_id = $W;
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -500);
COMMIT;
SQL
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.7
timeline "Fix 3 — REPEATABLE READ: A fails with SQLSTATE 40001 and must retry (nothing lost)" "$OUT"; reconcile

# ---------- Fix 4: optimistic locking with a version column ----------
cat > "$TMP/a.sql" <<SQL
BEGIN;
SELECT balance AS a_read, version AS a_ver FROM swiftmove.wallet WHERE wallet_id = $W \gset
SELECT pg_sleep(2) \g /dev/null
-- Only succeeds if nobody changed the row since A read it
UPDATE swiftmove.wallet SET balance = :a_read - 1000, version = version + 1 WHERE wallet_id = $W AND version = :a_ver;
\echo A: rows updated = :ROW_COUNT  (0 means conflict -> rollback and retry)
ROLLBACK;
-- Retry with fresh data:
BEGIN;
SELECT balance AS a_read, version AS a_ver FROM swiftmove.wallet WHERE wallet_id = $W \gset
UPDATE swiftmove.wallet SET balance = :a_read - 1000, version = version + 1 WHERE wallet_id = $W AND version = :a_ver;
\echo A retry: rows updated = :ROW_COUNT
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -1000);
COMMIT;
SQL
cat > "$TMP/b.sql" <<SQL
BEGIN;
SELECT balance AS b_read, version AS b_ver FROM swiftmove.wallet WHERE wallet_id = $W \gset
UPDATE swiftmove.wallet SET balance = :b_read - 500, version = version + 1 WHERE wallet_id = $W AND version = :b_ver;
\echo B: rows updated = :ROW_COUNT
INSERT INTO swiftmove.wallet_ledger (wallet_id, entry_type, amount) VALUES ($W, 'trip_debit', -500);
COMMIT;
SQL
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.7
timeline "Fix 4 — optimistic locking (version column, no locks held while the app thinks)" "$OUT"; reconcile
