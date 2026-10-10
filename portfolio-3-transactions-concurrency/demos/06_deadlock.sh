#!/bin/bash
# Demo 06 — Deadlock: two "split the fare" transfers between the same two rider wallets in
# opposite directions, each locking its source wallet first. Then the fix: lock in a global order.
cd "$(dirname "$0")"; . ./lib.sh
OUT="$EVID/06-deadlock.txt"; : > "$OUT"
W1=49981; W2=49982
restore() { psql -X -q -c "UPDATE swiftmove.wallet w SET balance = (SELECT sum(amount) FROM swiftmove.wallet_ledger l WHERE l.wallet_id = w.wallet_id) WHERE wallet_id IN ($W1,$W2)"; }
transfer() {  # transfer FROM TO ORDERED
  if [ "$3" = ordered ]; then
    LOCK="SELECT wallet_id FROM swiftmove.wallet WHERE wallet_id IN ($1, $2) ORDER BY wallet_id FOR UPDATE;"
  else LOCK="-- (no up-front ordered lock)"; fi
cat <<SQL
BEGIN;
$LOCK
UPDATE swiftmove.wallet SET balance = balance - 500 WHERE wallet_id = $1;
SELECT pg_sleep(1) \g /dev/null
UPDATE swiftmove.wallet SET balance = balance + 500 WHERE wallet_id = $2;
COMMIT;
SQL
}
transfer $W1 $W2 > "$TMP/a.sql"; transfer $W2 $W1 > "$TMP/b.sql"
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.3
timeline "Round 1 — A: $W1 -> $W2, B: $W2 -> $W1, each locks its source first (expect a deadlock)" "$OUT"; restore
transfer $W1 $W2 ordered > "$TMP/a.sql"; transfer $W2 $W1 ordered > "$TMP/b.sql"
session A "$TMP/a.sql"; session B "$TMP/b.sql" 0.3
timeline "Round 2 — both lock wallets in ascending wallet_id order first (B waits, no deadlock)" "$OUT"; restore
psql -X -c "SELECT deadlocks FROM pg_stat_database WHERE datname = 'swiftmove'" | tee -a "$OUT"
