#!/bin/bash
# Part C — MongoDB sharded cluster: config server replica set (27030), two shard replica sets
# shA (27031) and shB (27032), and a mongos router (27040). Trips are sharded on {city, _id}
# with ZONES: Lagos (about half of all trips) on shA, every other city on shB.
cd "$(dirname "$0")"; . ../../scripts/env.sh
OUT=../evidence/c-mongo-sharding.txt; : > $OUT
log() { echo "$@" | tee -a $OUT; }
ms() { mongosh --quiet --port $1 --eval "$2" 2>&1; }
for n in cfg shA shB mongos; do [ -f $VAR/mongo/$n.pid ] && kill $(cat $VAR/mongo/$n.pid) 2>/dev/null; done; sleep 2
rm -rf $VAR/mongo/{cfg,shA,shB}; mkdir -p $VAR/mongo/{cfg,shA,shB}
mongod --configsvr --replSet cfg --dbpath $VAR/mongo/cfg --port 27030 --bind_ip 127.0.0.1 --fork --logpath $VAR/log/mongo-cfg.log --pidfilepath $VAR/mongo/cfg.pid >/dev/null
mongod --shardsvr --replSet shA --dbpath $VAR/mongo/shA --port 27031 --bind_ip 127.0.0.1 --fork --logpath $VAR/log/mongo-shA.log --pidfilepath $VAR/mongo/shA.pid >/dev/null
mongod --shardsvr --replSet shB --dbpath $VAR/mongo/shB --port 27032 --bind_ip 127.0.0.1 --fork --logpath $VAR/log/mongo-shB.log --pidfilepath $VAR/mongo/shB.pid >/dev/null
ms 27030 'rs.initiate({_id: "cfg", configsvr: true, members: [{_id: 0, host: "localhost:27030"}]}).ok' >/dev/null
ms 27031 'rs.initiate({_id: "shA", members: [{_id: 0, host: "localhost:27031"}]}).ok' >/dev/null
ms 27032 'rs.initiate({_id: "shB", members: [{_id: 0, host: "localhost:27032"}]}).ok' >/dev/null
for p in 27030 27031 27032; do until [ "$(ms $p 'db.hello().isWritablePrimary')" = true ]; do sleep 0.5; done; done
mongos --configdb cfg/localhost:27030 --port 27040 --bind_ip 127.0.0.1 --fork --logpath $VAR/log/mongos.log --pidfilepath $VAR/mongo/mongos.pid >/dev/null
until ms 27040 'db.adminCommand({ping: 1}).ok' | grep -q 1; do sleep 0.5; done

log "=== C1. Cluster topology"
ms 27040 '
  sh.addShard("shA/localhost:27031"); sh.addShard("shB/localhost:27032");
  db.adminCommand({ listShards: 1 }).shards.forEach(s => print(`   shard ${s._id}: ${s.host}`));
  print("   router: mongos localhost:27040 | config servers: cfg/localhost:27030")' | tee -a $OUT
echo | tee -a $OUT

log "=== C2. Zone sharding: shard key {city: 1, _id: 1}; Lagos -> shA, all other cities -> shB"
ms 27040 '
  sh.addShardToZone("shA", "LAGOS"); sh.addShardToZone("shB", "REST_OF_NIGERIA");
  const ns = "swiftmove.trips";
  sh.updateZoneKeyRange(ns, { city: MinKey, _id: MinKey }, { city: "Lagos", _id: MinKey }, "REST_OF_NIGERIA");
  // Upper bound is "Lagos\u0000" (the smallest string greater than "Lagos"), not {Lagos, MaxKey}:
  // a query city = "Lagos" has the INCLUSIVE bound {Lagos, MaxKey}, which would otherwise touch the
  // first key of the next chunk and make the router contact shB as well (found in the first run).
  sh.updateZoneKeyRange(ns, { city: "Lagos", _id: MinKey }, { city: "Lagos\u0000", _id: MinKey }, "LAGOS");
  sh.updateZoneKeyRange(ns, { city: "Lagos\u0000", _id: MinKey }, { city: MaxKey, _id: MaxKey }, "REST_OF_NIGERIA");
  printjson(sh.shardCollection(ns, { city: 1, _id: 1 }).ok);
  db.getSiblingDB("config").tags.find({ ns }).sort({ min: 1 }).forEach(t => print(`   zone ${t.tag.padEnd(16)} ${EJSON.stringify(t.min)} -> ${EJSON.stringify(t.max)}`));' | tee -a $OUT
echo | tee -a $OUT

log "=== C3. Load all 107,535 trips through the router"
ms 27040 '
  const src = new Mongo("localhost:27017").getDB("swiftmove").trips;
  const dst = db.getSiblingDB("swiftmove").trips;
  let batch = [], n = 0; const t0 = Date.now();
  src.find().forEach(d => { batch.push(d); if (batch.length === 5000) { dst.insertMany(batch, { ordered: false }); n += batch.length; batch = []; } });
  if (batch.length) { dst.insertMany(batch, { ordered: false }); n += batch.length; }
  dst.createIndex({ city: 1, "rider.rider_id": 1, requested_at: -1 });
  dst.createIndex({ "rider.rider_id": 1, requested_at: -1 });
  print(`   inserted ${n} trips via mongos in ${Date.now() - t0} ms`);' | tee -a $OUT
log "--- documents per shard, read directly from each shard server:"
for p in 27031 27032; do ms $p 'const t = db.getSiblingDB("swiftmove").trips; print(`   ${db.hello().setName} (port ${db.hello().me.split(":")[1]}): ${t.countDocuments()} trips, cities = ${JSON.stringify(t.distinct("city").sort())}`)' | tee -a $OUT; done
log "--- the router's view (getShardDistribution):"
ms 27040 'db.getSiblingDB("swiftmove").trips.getShardDistribution()' | grep -E "Shard|data|docs|chunks|Totals" | sed 's/^/   /' | tee -a $OUT
echo | tee -a $OUT

log "=== C4. Query routing: targeted vs scatter-gather"
ms 27040 '
  const t = db.getSiblingDB("swiftmove").trips;
  const rider = t.findOne({ city: "Lagos" }).rider.rider_id;
  const summary = (label, cursor) => {
    const e = cursor.explain("executionStats");
    const wp = e.queryPlanner.winningPlan;
    const shards = (wp.shards || []).map(s => s.shardName);
    print(`   ${label}`);
    print(`      router stage: ${wp.stage}   shards contacted: ${JSON.stringify(shards)}   nReturned: ${e.executionStats.nReturned}   docs examined: ${e.executionStats.totalDocsExamined}`);
  };
  summary(`city = "Lagos" AND rider = ${rider}   (shard key prefix present)`, t.find({ city: "Lagos", "rider.rider_id": rider }));
  summary(`rider = ${rider} only                 (no shard key)`, t.find({ "rider.rider_id": rider }));
  summary(`city IN ["Kano","Abuja"]              (both in one zone)`, t.find({ city: { $in: ["Kano", "Abuja"] }, status: "requested" }));
  const agg = t.explain().aggregate([{ $group: { _id: "$city", trips: { $sum: 1 } } }]);
  print(`   aggregate $group by city: split into per-shard partial groups + merge on ${agg.mergeType || "router"}; shards: ${JSON.stringify(Object.keys(agg.shards || {}))}`);' | tee -a $OUT
echo | tee -a $OUT

log "=== C5. Comparison: a hashed shard key spreads data evenly but loses city locality"
ms 27040 '
  const s = db.getSiblingDB("swiftmove");
  sh.shardCollection("swiftmove.trips_hashed", { _id: "hashed" });
  const docs = s.trips.find().limit(50000).toArray(); s.trips_hashed.insertMany(docs, { ordered: false });
  print("   trips_hashed (50,000 docs), documents per shard:");' | tee -a $OUT
for p in 27031 27032; do ms $p 'print(`      ${db.hello().setName}: ${db.getSiblingDB("swiftmove").trips_hashed.countDocuments()}`)' | tee -a $OUT; done
ms 27040 '
  const e = db.getSiblingDB("swiftmove").trips_hashed.find({ city: "Lagos", status: "requested" }).explain("queryPlanner");
  print(`   query city = "Lagos" on hashed collection -> ${e.queryPlanner.winningPlan.stage}, shards: ${JSON.stringify(e.queryPlanner.winningPlan.shards.map(x => x.shardName))}`);' | tee -a $OUT
