// Portfolio 4 — demonstrations on the SwiftMove MongoDB model.
// Run: mongosh --quiet --port 27017 demos.js | tee evidence/demo-output.txt   (~75 s: the TTL demo waits)
const sm = db.getSiblingDB("swiftmove");
const h = (t) => print(`\n${"=".repeat(100)}\n${t}\n${"=".repeat(100)}`);
const show = (x) => printjson(x);
const plan = (e) => {           // compact summary of explain("executionStats")
  const s = e.executionStats;
  const stages = [];
  (function walk(p) { if (!p) return; stages.push(p.stage + (p.indexName ? `(${p.indexName})` : "")); walk(p.inputStage); (p.inputStages || []).forEach(walk); })(e.queryPlanner.winningPlan.queryPlan || e.queryPlanner.winningPlan);
  return { plan: stages.join(" <- "), nReturned: s.nReturned, totalKeysExamined: s.totalKeysExamined, totalDocsExamined: s.totalDocsExamined, executionTimeMillis: s.executionTimeMillis };
};

h("0. What was loaded");
show({ trips: sm.trips.countDocuments(), drivers: sm.drivers.countDocuments(), riders: sm.riders.countDocuments(),
       deliveries_with_parcel: sm.trips.countDocuments({ parcel: { $exists: true } }),
       rides_without_parcel: sm.trips.countDocuments({ type: "ride", parcel: { $exists: false } }) });

h("1. Document model: ONE read returns the whole trip (PostgreSQL needs 9 tables / 8 joins for the same view)");
show(sm.trips.findOne({ type: "delivery", status: "completed", "ratings.rider_to_driver": { $exists: true } }));

h("2. Schema validation rejects bad documents");
for (const [label, doc] of [
  ["status not in enum", { _id: -1, type: "ride", status: "teleported", category: "ECONOMY", city: "Lagos", requested_at: new Date(), rider: { rider_id: 1, name: "x" },
    pickup: { zone: "Yaba", location: { type: "Point", coordinates: [3.37, 6.5] } }, dropoff: { zone: "Yaba", location: { type: "Point", coordinates: [3.37, 6.5] } }, status_history: [{ status: "requested", at: new Date() }] }],
  ["completed trip without driver/fare (business rule)", { _id: -2, type: "ride", status: "completed", category: "ECONOMY", city: "Lagos", requested_at: new Date(), rider: { rider_id: 1, name: "x" },
    pickup: { zone: "Yaba", location: { type: "Point", coordinates: [3.37, 6.5] } }, dropoff: { zone: "Yaba", location: { type: "Point", coordinates: [3.37, 6.5] } }, status_history: [{ status: "requested", at: new Date() }] }],
]) {
  try { sm.trips.insertOne(doc); print(`  ${label}: INSERTED (unexpected!)`); }
  catch (e) {
    print(`  ${label}: REJECTED -> code ${e.code}: ${e.errmsg || e.message}`);
    print(`      why: ${JSON.stringify(e.errInfo && e.errInfo.details).slice(0, 400)}`);
  }
}

h("3. Indexing: rider trip history — COLLSCAN vs compound index (same query as Postgres Q1)");
const heavy = sm.trips.aggregate([{ $group: { _id: "$rider.rider_id", n: { $sum: 1 } } }, { $sort: { n: -1 } }, { $limit: 1 }]).toArray()[0];
print(`  rider ${heavy._id} has ${heavy.n} trips in this collection`);
const q3 = () => sm.trips.find({ "rider.rider_id": heavy._id }, { _id: 1, requested_at: 1, status: 1, "pickup.zone": 1, "fare.amount": 1 }).sort({ requested_at: -1 }).limit(20);
sm.trips.dropIndexes();
print("  BEFORE:"); show(plan(q3().explain("executionStats")));
sm.trips.createIndex({ "rider.rider_id": 1, requested_at: -1 }, { name: "rider_history" });
print("  AFTER createIndex({'rider.rider_id': 1, requested_at: -1}):"); show(plan(q3().explain("executionStats")));
print("  first 3 results:"); q3().limit(3).forEach(show);

h("4. Geospatial: 5 nearest AVAILABLE ECONOMY drivers within 3 km of a pickup in Lekki Phase 1");
sm.drivers.createIndex({ location: "2dsphere", availability: 1, "vehicle.category": 1 }, { name: "geo_dispatch" });
const pickup = { type: "Point", coordinates: [3.4723, 6.4478] };
const nearest = [{ $geoNear: { near: pickup, distanceField: "distance_m", maxDistance: 3000, spherical: true,
                               query: { availability: "available", "vehicle.category": "ECONOMY" } } },
                 { $limit: 5 }, { $project: { _id: 1, name: 1, zone: 1, "vehicle.plate": 1, distance_m: { $round: ["$distance_m", 0] } } }];
sm.drivers.aggregate(nearest).forEach(show);
// Same search as a find() with $near, so explain() shows the index used:
const ge = sm.drivers.find({ location: { $near: { $geometry: pickup, $maxDistance: 3000 } }, availability: "available", "vehicle.category": "ECONOMY" }).limit(5).explain("executionStats");
print("  explain:"); show(plan(ge));
print(`  (${sm.drivers.countDocuments()} drivers in total; the 2dsphere index limits the search to nearby cells)`);

h("5. Atomic single-document update: a driver accepts a requested trip (only if still requested)");
const open = sm.trips.findOne({ status: "requested", city: "Lagos" });
const accept = () => sm.trips.findOneAndUpdate(
  { _id: open._id, status: "requested" },                                   // condition = optimistic check
  { $set: { status: "accepted", driver: { driver_id: 7, name: "Demo Driver", vehicle: { plate: "LAG-00007SM" } } },
    $push: { status_history: { status: "accepted", at: new Date() } } },
  { returnDocument: "after", projection: { status: 1, status_history: 1, "driver.driver_id": 1 } });
print("  first dispatcher:"); show(accept());
print("  second dispatcher (same trip, a moment later):"); show(accept());
print("  -> null: the filter no longer matches, so the second accept is a no-op (no double assignment).");

h("6. Aggregation pipeline: top 5 Lagos drivers by earnings, last 30 days (net of commission)");
sm.trips.aggregate([
  { $match: { city: "Lagos", status: "completed", requested_at: { $gte: new Date("2026-09-10T00:00:00+01:00") } } },
  { $group: { _id: "$driver.driver_id", name: { $first: "$driver.name" }, trips: { $sum: 1 },
              gross: { $sum: "$fare.amount" }, net: { $sum: { $subtract: ["$fare.amount", "$fare.commission"] } },
              rating: { $avg: "$ratings.rider_to_driver.score" } } },
  { $sort: { net: -1 } }, { $limit: 5 },
  { $project: { name: 1, trips: 1, gross: { $round: ["$gross", 2] }, net: { $round: ["$net", 2] }, rating: { $round: ["$rating", 2] } } },
]).forEach(show);

h("6b. Aggregation: demand heat-map — busiest pickup zone per city and payment-method mix ($facet)");
show(sm.trips.aggregate([{ $facet: {
  busiest_zone_per_city: [{ $group: { _id: { city: "$city", zone: "$pickup.zone" }, n: { $sum: 1 } } }, { $sort: { n: -1 } },
                          { $group: { _id: "$_id.city", zone: { $first: "$_id.zone" }, requests: { $first: "$n" } } }, { $sort: { requests: -1 } }],
  payment_mix: [{ $match: { "payment.method": { $exists: true } } }, { $group: { _id: "$payment.method", n: { $sum: 1 } } }, { $sort: { n: -1 } }],
} }]).toArray()[0]);

h("7. Key-value pattern with TTL: driver presence heartbeats (key = 'driver:<id>')");
sm.driver_presence.drop();
sm.driver_presence.createIndex({ last_seen: 1 }, { expireAfterSeconds: 30, name: "ttl_30s" });
const now = new Date();
sm.driver_presence.insertMany([
  { _id: "driver:4999", last_seen: now, loc: [8.52, 11.98], app_version: "5.2.1" },
  { _id: "driver:1743", last_seen: now, loc: [3.29, 6.47], app_version: "5.2.0" },
  { _id: "driver:0069", last_seen: new Date(now - 120000), loc: [3.47, 6.44], app_version: "5.1.9" },   // went offline 2 min ago
]);
print("  GET driver:4999 ->"); show(sm.driver_presence.findOne({ _id: "driver:4999" }));
print(`  keys now: ${JSON.stringify(sm.driver_presence.find({}, { _id: 1 }).toArray().map((d) => d._id))}`);
print("  PUT (upsert) refreshes a heartbeat:");
sm.driver_presence.updateOne({ _id: "driver:1743" }, { $set: { last_seen: new Date(), loc: [3.30, 6.48] } }, { upsert: true });
print("  waiting 65 s for the TTL monitor (runs every 60 s); drivers 4999 and 1743 keep sending a heartbeat every 10 s...");
for (let i = 0; i < 7; i++) {
  sleep(i < 6 ? 10000 : 5000);
  sm.driver_presence.updateMany({ _id: { $in: ["driver:4999", "driver:1743"] } }, { $set: { last_seen: new Date() } });
}
print(`  keys after 65 s: ${JSON.stringify(sm.driver_presence.find({}, { _id: 1 }).toArray().map((d) => d._id))}`);
print("  -> the driver that stopped sending heartbeats (driver:0069) expired automatically; live drivers stay. No cron job needed.");

h("8. Graph pattern: referral network with $graphLookup");
const amb = sm.riders.aggregate([{ $match: { referred_by: { $exists: true } } }, { $group: { _id: "$referred_by", direct: { $sum: 1 } } }, { $sort: { direct: -1 } }, { $limit: 1 }]).toArray()[0];
sm.riders.createIndex({ referred_by: 1 });
print(`  top ambassador: rider ${amb._id} with ${amb.direct} direct referrals`);
show(sm.riders.aggregate([
  { $match: { _id: amb._id } },
  { $graphLookup: { from: "riders", startWith: "$_id", connectFromField: "_id", connectToField: "referred_by", as: "network", maxDepth: 3, depthField: "depth" } },
  { $project: { name: 1, city: 1, network_size: { $size: "$network" },
                by_depth: { $map: { input: [0, 1, 2, 3], as: "d", in: { depth: { $add: ["$$d", 1] }, riders: { $size: { $filter: { input: "$network", cond: { $eq: ["$$this.depth", "$$d"] } } } } } } } } },
]).toArray()[0]);
const leaf = sm.riders.findOne({ referred_by: { $exists: true }, _id: { $gt: 20000, $lt: 25000 } });
print(`  upline (who invited whom) for rider ${leaf._id}:`);
show(sm.riders.aggregate([
  { $match: { _id: leaf._id } },
  { $graphLookup: { from: "riders", startWith: "$referred_by", connectFromField: "referred_by", connectToField: "_id", as: "chain", depthField: "hops" } },
  { $project: { name: 1, chain: { $map: { input: { $sortArray: { input: "$chain", sortBy: { hops: 1 } } }, as: "c", in: { rider: "$$c._id", name: "$$c.name", hops: { $add: ["$$c.hops", 1] } } } } } },
]).toArray()[0]);

h("9. Storage footprint vs PostgreSQL");
const st = sm.trips.stats();
show({ documents: st.count, avg_document_bytes: st.avgObjSize, data_MB: +(st.size / 1048576).toFixed(1),
       on_disk_compressed_MB: +(st.storageSize / 1048576).toFixed(1), index_MB: +(st.totalIndexSize / 1048576).toFixed(1) });
