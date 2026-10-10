#!/bin/bash
# Portfolio 4: export from PostgreSQL, load into MongoDB, run the demos (writes evidence/demo-output.txt).
set -e
cd "$(dirname "$0")"; . ../scripts/env.sh
../scripts/start-mongo.sh
mkdir -p data evidence
psql -X -q -f export_from_postgres.sql
mongosh --quiet --port 27017 load.js | tee evidence/load-output.txt
mongosh --quiet --port 27017 demos.js | tee evidence/demo-output.txt
