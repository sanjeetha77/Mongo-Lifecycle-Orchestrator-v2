#!/usr/bin/env bash
# seed_data.sh
# Populates MongoDB with test data to verify integrity after upgrades.

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }

# Check for Auth
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="-u $MONGO_ADMIN_USER -p $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi

log "🌱 Seeding 1,000 documents into database: sanj, collection: sanj..."

# Generate and Insert Data
mongosh $AUTH_ARGS --quiet --eval "
  const dbName = 'sanj';
  const collName = 'sanj';
  const dbObj = db.getSiblingDB(dbName);
  
  // Clear old data
  dbObj[collName].drop();
  
  const docs = [];
  for (let i = 1; i <= 1000; i++) {
    docs.push({
      record_id: i,
      timestamp: new Date(),
      status: 'baseline_test',
      metadata: {
        node: 'prism-azure-host',
        project: 'mongo-lifecycle-automation'
      }
    });
  }
  
  const result = dbObj[collName].insertMany(docs);
  print('✅ Successfully inserted ' + result.insertedCount + ' documents.');
"
