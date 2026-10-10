#!/bin/bash
# Part B — MongoDB 3-member replica set (rs0) on ports 27021-27023.
# Shows: election of a primary, majority writes, secondary reads, automatic failover after the
# primary is killed, loss of majority (no primary => writes refused), and recovery.
cd "$(dirname "$0")"; . ../../scripts/env.sh
OUT=../evidence/b-mongo-replica-set.txt; : > $OUT
log() { echo "$@" | tee -a $OUT; }
ms() { mongosh --quiet --port $1 --eval "$2" 2>&1; }
URI="mongodb://localhost:27021,localhost:27022,localhost:27023/swiftmove?replicaSet=rs0"
now() { perl -MTime::HiRes=time -e 'print time'; }
start_node() { mkdir -p $VAR/mongo/rs$1; mongod --replSet rs0 --dbpath $VAR/mongo/rs$1 --port 2702$1 --bind_ip 127.0.0.1 \
  --fork --logpath $VAR/log/mongo-rs$1.log --pidfilepath $VAR/mongo/rs$1.pid >/dev/null; }
kill_node() { kill -9 $(cat $VAR/mongo/rs$1.pid); rm -f $VAR/mongo/rs$1.pid; }
members() { mongosh --quiet "$URI&readPreference=primaryPreferred" --eval 'rs.status().members.forEach(m => print(`   ${m.name}  ${m.stateStr.padEnd(10)} health=${m.health}`))' 2>/dev/null \
  || ms ${1:-27021} 'rs.status().members.forEach(m => print(`   ${m.name}  ${m.stateStr.padEnd(10)} health=${m.health}`))'; }

# fresh start
for i in 1 2 3; do [ -f $VAR/mongo/rs$i.pid ] && kill -9 $(cat $VAR/mongo/rs$i.pid) 2>/dev/null; rm -rf $VAR/mongo/rs$i $VAR/mongo/rs$i.pid; done
sleep 1
for i in 1 2 3; do start_node $i; done

log "=== B1. Initiate the replica set and wait for an election"
ms 27021 'rs.initiate({_id: "rs0", members: [{_id: 0, host: "localhost:27021"}, {_id: 1, host: "localhost:27022"}, {_id: 2, host: "localhost:27023"}]}).ok' | tee -a $OUT
until [ "$(ms 27021 'db.hello().isWritablePrimary' )" = true ]; do sleep 0.5; done
members | tee -a $OUT
ms 27021 'const c = rs.conf(); print(`   electionTimeoutMillis=${c.settings.electionTimeoutMillis}  heartbeatIntervalMillis=${c.settings.heartbeatIntervalMillis}  writeConcernMajorityJournalDefault=${c.writeConcernMajorityJournalDefault}`)' | tee -a $OUT
echo | tee -a $OUT

log "=== B2. Load 20,000 trips (copied from the Portfolio 4 standalone) with writeConcern majority"
mongosh --quiet "$URI" --eval '
  const src = new Mongo("localhost:27017").getDB("swiftmove").trips;
  const dst = db.trips; dst.drop();
  let batch = [], n = 0; const t0 = Date.now();
  src.find().sort({ _id: -1 }).limit(20000).forEach(d => { batch.push(d); if (batch.length === 2000) { dst.insertMany(batch, { writeConcern: { w: "majority" } }); n += batch.length; batch = []; } });
  if (batch.length) { dst.insertMany(batch, { writeConcern: { w: "majority" } }); n += batch.length; }
  dst.createIndex({ "rider.rider_id": 1, requested_at: -1 });
  print(`   inserted ${n} trips in ${Date.now() - t0} ms (each batch acknowledged by >= 2 of 3 members)`);' | tee -a $OUT
log "--- read the same data from each member (secondaryOk reads):"
for p in 27021 27022 27023; do ms $p 'db.getMongo().setReadPref("secondaryPreferred"); print(`   ${db.hello().me} (${db.hello().isWritablePrimary ? "PRIMARY" : "SECONDARY"}): trips = ${db.getSiblingDB("swiftmove").trips.countDocuments()}`)' | tee -a $OUT; done
log "--- secondary replication lag:"
ms 27021 'rs.printSecondaryReplicationInfo()' | grep -E "source|behind" | sed 's/^/   /' | tee -a $OUT
echo | tee -a $OUT

log "=== B3. Write concern trade-off: 2,000 single-document inserts, w:1 vs w:\"majority\""
mongosh --quiet "$URI" --eval '
  for (const w of [1, "majority"]) {
    const t0 = Date.now();
    for (let i = 0; i < 2000; i++) db.wc_test.insertOne({ i, w: String(w) }, { writeConcern: { w } });
    print(`   w:${JSON.stringify(w).padEnd(10)} ${((Date.now() - t0) / 2000).toFixed(3)} ms per insert`);
  }
  db.wc_test.drop();' | tee -a $OUT
echo | tee -a $OUT

log "=== B4. Failover: kill -9 the primary, measure time until a new primary accepts writes"
PRIM=$(ms 27021 'db.hello().primary' ); log "   current primary: $PRIM"
N=${PRIM: -1}
mongosh --quiet "$URI" --eval 'db.trips.updateOne({}, { $set: { failover_marker: "written before crash" } }, { writeConcern: { w: "majority" } }); print("   majority write committed before the crash")' | tee -a $OUT
T0=$(now); kill_node $N; log "   killed $PRIM (SIGKILL)"
NEWP=""
while [ -z "$NEWP" ]; do
  for p in 27021 27022 27023; do [ $p = 2702$N ] && continue
    [ "$(mongosh --quiet --port $p --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = true ] && NEWP=localhost:$p; done
  sleep 0.2
done
perl -e "printf \"   new primary %s elected after %.1f s\n\", '$NEWP', $(now) - $T0" | tee -a $OUT
members $NEWP | tee -a $OUT
mongosh --quiet "$URI" --eval '
  print(`   marker survived failover: ${db.trips.countDocuments({ failover_marker: "written before crash" })} document(s)`);
  const r = db.trips.insertOne({ _id: -100, note: "written on the new primary with 2/3 members up" }, { writeConcern: { w: "majority", wtimeout: 5000 } });
  print(`   majority write with 2 of 3 members: acknowledged=${r.acknowledged}`);' | tee -a $OUT
echo | tee -a $OUT

log "=== B5. Lose the majority: kill a second member (1 of 3 left)"
M2=${NEWP: -1}; kill_node $((M2 - 0)); log "   killed localhost:2702$M2"
LAST=$(for i in 1 2 3; do [ -f $VAR/mongo/rs$i.pid ] && echo 2702$i; done)
sleep 12
ms $LAST 'print(`   surviving member ${db.hello().me}: isWritablePrimary=${db.hello().isWritablePrimary}, state=${rs.status().members.find(m => m.self).stateStr}`)' | tee -a $OUT
ms $LAST 'try { db.getSiblingDB("swiftmove").trips.insertOne({ _id: -101 }); print("   write accepted (unexpected)"); } catch (e) { print(`   write refused: ${e.codeName || e.message}`); }' | tee -a $OUT
ms $LAST 'db.getMongo().setReadPref("secondary"); print(`   read still served by the secondary: trips = ${db.getSiblingDB("swiftmove").trips.countDocuments()} (may be stale, readConcern "local")`)' | tee -a $OUT
log "   -> with no majority, MongoDB chooses consistency: no primary, no writes (CP), but secondary reads stay available."
echo | tee -a $OUT

log "=== B6. Recovery: restart both failed members; they rejoin and catch up"
for i in 1 2 3; do [ -f $VAR/mongo/rs$i.pid ] || start_node $i; done
T0=$(now)
until [ "$(mongosh --quiet "$URI" --eval 'rs.status().members.filter(m => m.stateStr === "PRIMARY" || m.stateStr === "SECONDARY").length' 2>/dev/null)" = 3 ]; do sleep 0.5; done
perl -e "printf \"   all 3 members healthy again after %.1f s\n\", $(now) - $T0" | tee -a $OUT
members | tee -a $OUT
for p in 27021 27022 27023; do ms $p 'db.getMongo().setReadPref("secondaryPreferred"); const t = db.getSiblingDB("swiftmove").trips; print(`   ${db.hello().me}: trips=${t.countDocuments()}  post-failover doc present=${t.countDocuments({ _id: -100 })}`)' | tee -a $OUT; done
