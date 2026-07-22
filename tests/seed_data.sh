#!/usr/bin/env bash
# seed_data.sh
# Production-ready seed script for MongoDB replica set.
# Dynamically detects the PRIMARY replica member and inserts 1000 documents.

set -Eeuo pipefail

# 1. Load config file
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Configuration file config.env not found at: $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

# 2. Helper functions for proper logging format
log_info() {
    echo "[INFO] $*"
}

log_success() {
    echo "[SUCCESS] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

# 3. Ensure Docker CLI is available
if ! command -v docker &> /dev/null; then
    log_error "docker command is required but not found in PATH."
    exit 1
fi

# 4. Build Authentication Arguments if AUTH_ENABLED is true
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="-u $MONGO_ADMIN_USER -p $MONGO_ADMIN_PASS --authenticationDatabase $MONGO_AUTH_DB"
fi

# 5. Determine which replica member to query for finding the PRIMARY.
# Allows configuration using MONGO_QUERY_NODE in config.env, defaulting to MONGO1 (or mongo1).
QUERY_NODE="${MONGO_QUERY_NODE:-${MONGO1:-mongo1}}"

log_info "Detecting PRIMARY node..."

# 6. Execute rs.status() against the configured QUERY_NODE using mongosh to identify the PRIMARY node.
ERR_OUT=$(mktemp)
PRIMARY_NODE=$(docker exec "$QUERY_NODE" mongosh $AUTH_ARGS --quiet --eval "
    try {
        const status = rs.status();
        if (status.ok === 1) {
            const primary = status.members.find(m => m.state === 1 || m.stateStr === 'PRIMARY');
            if (primary && primary.name) {
                // Extract host/container name by stripping port number (e.g. mongo2:27017 -> mongo2)
                print(primary.name.split(':')[0]);
            }
        }
    } catch(err) {
        console.error(err.message || err);
    }
" 2>"$ERR_OUT" | tr -d '\r\n[:space:]')

# 7. Fail gracefully with error if PRIMARY cannot be detected
if [[ -z "$PRIMARY_NODE" ]]; then
    log_error "Could not detect PRIMARY node from replica member: $QUERY_NODE"
    if [[ -f "$ERR_OUT" && -s "$ERR_OUT" ]]; then
        log_error "Details: $(cat "$ERR_OUT")"
    fi
    rm -f "$ERR_OUT"
    exit 1
fi
rm -f "$ERR_OUT"

log_info "PRIMARY node detected: $PRIMARY_NODE"

# 8. Connect to the detected PRIMARY container and seed 1000 documents
log_info "Connecting to PRIMARY..."
log_info "Seeding 1000 documents..."

# We execute mongosh inside the detected PRIMARY container.
# Old metadata node field 'prism-azure-host' is replaced with the detected PRIMARY node name.
SEED_OUT=$(docker exec "$PRIMARY_NODE" mongosh $AUTH_ARGS --quiet --eval "
    const dbName = 'sanj';
    const collName = 'sanj';
    const dbObj = db.getSiblingDB(dbName);

    try {
        // Clear previous seed data
        dbObj[collName].drop();

        const docs = [];
        for (let i = 1; i <= 1000; i++) {
            docs.push({
                record_id: i,
                timestamp: new Date(),
                status: 'baseline_test',
                metadata: {
                    node: '${PRIMARY_NODE}',
                    project: 'mongo-lifecycle-automation'
                }
            });
        }

        const result = dbObj[collName].insertMany(docs);
        const count = result && (typeof result.insertedCount === 'number' ? result.insertedCount : (result.insertedIds ? Object.keys(result.insertedIds).length : 0));
        if (count === 1000) {
            print('SUCCESS_INSERT_1000');
        } else {
            console.error('Error: Only ' + count + ' documents were inserted.');
        }
    } catch (err) {
        console.error(err.message || err);
    }
" 2>&1)

# 9. Verify success and output confirmation
if [[ "$SEED_OUT" == *"SUCCESS_INSERT_1000"* ]]; then
    log_success "1000 documents inserted successfully."
else
    log_error "Failed to seed documents into database."
    log_error "Details: $SEED_OUT"
    exit 1
fi
