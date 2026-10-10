#!/bin/bash
# Demo 03 — READ COMMITTED allows a non-repeatable read; REPEATABLE READ (snapshot) does not.
cd "$(dirname "$0")"; . ./lib.sh
OUT="$EVID/03-non-repeatable-read.txt"; : > "$OUT"
W=49961   # wallet of rider 49960
for LEVEL in "READ COMMITTED" "REPEATABLE READ"; do
cat > "$TMP/a.sql" <<SQL
-- A (finance report) reads the same balance twice inside one transaction
BEGIN ISOLATION LEVEL $LEVEL;
SELECT balance AS first_read FROM swiftmove.wallet WHERE wallet_id = $W;
SELECT pg_sleep(2) \g /dev/null
SELECT balance AS second_read FROM swiftmove.wallet WHERE wallet_id = $W;
COMMIT;
SQL
cat > "$TMP/b.sql" <<SQL
-- B (rider) tops up NGN 1,000 and commits while A is still running
BEGIN;
SELECT swiftmove.topup(49960, 1000) AS new_balance;
COMMIT;
SQL
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.7
timeline "Isolation level of A: $LEVEL" "$OUT"
done
