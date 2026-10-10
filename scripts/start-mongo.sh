#!/bin/bash
# Start a standalone MongoDB 8 on port 27017 for Portfolio 4.
. "$(dirname "$0")/env.sh"
mkdir -p "$VAR/mongo/p4" "$VAR/log"
pgrep -f "mongod --dbpath $VAR/mongo/p4" >/dev/null || \
  mongod --dbpath "$VAR/mongo/p4" --port 27017 --bind_ip 127.0.0.1 --fork --logpath "$VAR/log/mongo-p4.log"
mongosh --quiet --port 27017 --eval 'print("MongoDB up: " + db.version())'
