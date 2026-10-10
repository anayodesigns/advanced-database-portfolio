#!/bin/bash
# Stop every database server started by the portfolio scripts.
. "$(dirname "$0")/env.sh"
for d in "$VAR/pg/primary" "$VAR/pg/replica"; do [ -d "$d" ] && pg_ctl -D "$d" stop -m fast 2>/dev/null; done
for n in mongos shA shB cfg rs1 rs2 rs3; do [ -f "$VAR/mongo/$n.pid" ] && kill "$(cat "$VAR/mongo/$n.pid")" 2>/dev/null && rm -f "$VAR/mongo/$n.pid"; done
pkill -f "mongod --dbpath $VAR/mongo/p4" 2>/dev/null
echo "All portfolio database servers stopped."
