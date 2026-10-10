#!/bin/bash
# Portfolio 5: runs Parts A-D and rewrites evidence/. Needs the Portfolio 1-4 PostgreSQL (5433)
# and MongoDB (27017) servers running. About 4 minutes.
set -e
cd "$(dirname "$0")"; . ../scripts/env.sh
scripts/a_postgres_replication.sh > /dev/null
scripts/b_mongo_replica_set.sh   > /dev/null
scripts/c_mongo_sharding.sh      > /dev/null
psql -X -f scripts/d_postgres_partitioning.sql > evidence/d-postgres-partitioning.txt 2>&1
echo "Evidence written:"; ls -1 evidence
