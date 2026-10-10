// Portfolio 4 — load SwiftMove into MongoDB (database "swiftmove").
// Run: mongosh --quiet --port 27017 load.js     (from this folder, after export_from_postgres.sql)
const fs = require("fs");
const sm = db.getSiblingDB("swiftmove");
sm.dropDatabase();

// ---------- 1. trips: document model with JSON-Schema validation ----------
const point = { bsonType: "object", required: ["type", "coordinates"],
  properties: { type: { enum: ["Point"] }, coordinates: { bsonType: "array", minItems: 2, maxItems: 2, items: { bsonType: "double" } } } };
sm.createCollection("trips", {
  validator: { $and: [ { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "type", "status", "category", "city", "requested_at", "rider", "pickup", "dropoff", "status_history"],
    properties: {
      type: { enum: ["ride", "delivery"] },
      status: { enum: ["requested", "accepted", "in_progress", "completed", "cancelled"] },
      category: { enum: ["ECONOMY", "COMFORT", "BIKE", "VAN"] },
      requested_at: { bsonType: "date" },
      rider: { bsonType: "object", required: ["rider_id", "name"] },
      pickup: { bsonType: "object", required: ["zone", "location"], properties: { location: point } },
      dropoff: { bsonType: "object", required: ["zone", "location"], properties: { location: point } },
      status_history: { bsonType: "array", minItems: 1, items: { bsonType: "object", required: ["status", "at"], properties: { at: { bsonType: "date" } } } },
      fare: { bsonType: "object", required: ["amount", "currency"], properties: { amount: { bsonType: ["double", "int", "decimal"], minimum: 0 } } },
      parcel: { bsonType: "object", required: ["recipient", "size"], properties: { size: { enum: ["S", "M", "L"] } } },
    },
  } },
    // Business rule from Portfolio 1 (ck_trip_completed): a completed trip must have a driver and a fare.
    // $jsonSchema has no if/then, so the conditional rule is a query expression combined with $and.
    { $or: [ { status: { $ne: "completed" } }, { driver: { $exists: true }, fare: { $exists: true } } ] },
  ] },
  validationLevel: "strict", validationAction: "error",
});

const toDate = (s) => (s ? new Date(s) : s);
function fixTrip(t) {
  t.requested_at = toDate(t.requested_at);
  t.status_history.forEach((e) => (e.at = toDate(e.at)));
  if (t.payment) t.payment.settled_at = toDate(t.payment.settled_at);
  // JSON numbers like 1870.00 would arrive as ints; store money and coordinates as doubles.
  if (t.fare) for (const k of ["amount", "commission", "distance_km", "duration_min"]) t.fare[k] = Double(t.fare[k]);
  for (const p of [t.pickup, t.dropoff]) p.location.coordinates = p.location.coordinates.map((x) => Double(x));
  return t;
}
function loadNdjson(file, coll, fix) {
  const lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l.length);
  let batch = [];
  for (const line of lines) {
    batch.push(fix(JSON.parse(line)));
    if (batch.length === 5000) { coll.insertMany(batch, { ordered: false }); batch = []; }
  }
  if (batch.length) coll.insertMany(batch, { ordered: false });
  return lines.length;
}
const t0 = Date.now();
print(`trips loaded:   ${loadNdjson("data/trips.ndjson", sm.trips, fixTrip)}  (${Date.now() - t0} ms)`);

// ---------- 2. drivers: live location (GeoJSON) for nearest-driver search ----------
let seed = 7;
const rnd = () => ((seed = (seed * 9301 + 49297) % 233280) / 233280);
print(`drivers loaded: ${loadNdjson("data/drivers.ndjson", sm.drivers, (d) => {
  const z = d.zones[Math.floor(rnd() * d.zones.length)];
  delete d.zones;
  const r = rnd();
  d.availability = d.status !== "approved" ? "offline" : r < 0.45 ? "available" : r < 0.8 ? "on_trip" : "offline";
  d.location = { type: "Point", coordinates: [Double(z.lng + (rnd() - 0.5) * 0.03), Double(z.lat + (rnd() - 0.5) * 0.03)] };
  d.zone = z.zone;
  d.location_updated_at = new Date();
  return d;
})}`);

// ---------- 3. riders + referral graph (who invited whom) ----------
// ~60% of riders were referred by an earlier rider in the same city; a few "ambassadors" refer many.
const cityFirst = {};
print(`riders loaded:  ${loadNdjson("data/riders.ndjson", sm.riders, (r) => {
  if (cityFirst[r.city] === undefined) cityFirst[r.city] = r._id;
  const span = r._id - cityFirst[r.city];
  if (span > 10 && rnd() < 0.6) {
    r.referred_by = rnd() < 0.3 ? cityFirst[r.city] + Math.floor(rnd() * 20)        // ambassadors
                                : cityFirst[r.city] + Math.floor(Math.pow(rnd(), 0.7) * span);
  }
  return r;
})}`);

print(`collections: ${JSON.stringify(sm.getCollectionNames().sort())}`);
