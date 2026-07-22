#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_VER="7.0.14"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
if [[ "${MODE:-docker}" == "docker" ]]; then
    source "$BASE_DIR/modules/docker_upgrade.sh"
fi
LOG_FILE="/var/log/mongodb-rollback.log"
TS="$(date +'%Y%m%d-%H%M%S')"
BACKUP_DIR="/var/backups/mongodb-rollback-8to7-$TS"
mkdir -p "$BACKUP_DIR"

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
fail() { log "❌ ERROR: $1"; exit 1; }

log "=== 🛡️ Rollback 8.0 → 7.0 START ==="

# STEP 1: Lower FCV while 8.0 binaries are still present
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi

log "Lowering featureCompatibilityVersion to 7.0..."
if [[ "$MODE" == "docker" ]]; then
    FCV_NODE=$(get_primary_node || echo "$MONGO1")
    sudo docker exec "$FCV_NODE" mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '7.0', confirm: true}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
else
    mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '7.0', confirm: true}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
fi

# STEP 2: Context-Aware Backup
if [[ "$MODE" == "docker" ]]; then
    BACKUP_NODE=$(get_primary_node || echo "$MONGO1")
    log "Backing up Docker container $BACKUP_NODE..."
    sudo docker exec "$BACKUP_NODE" mongodump $AUTH_ARGS --archive > "$BACKUP_DIR/pre_rollback_8.0.archive"
else
    sudo mongodump $AUTH_ARGS --out "$BACKUP_DIR/dump" > /dev/null 2>&1 || true
fi

# STEP 3: Rollback execution based on MODE
if [[ "$MODE" == "docker" ]]; then
    log "MODE=docker: Recreating Docker containers with target version 7.0..."
    source "$BASE_DIR/modules/docker_upgrade.sh"
    upgrade_docker_replica_set "7.0" "rollback"
    log "✅ Rollback to 7.0 complete in Docker."
else
    log "MODE=systemd: Downgrading MongoDB host binaries..."
    # STEP 3.1: FORCE REMOVE VERSION 8 REPO
    log "Purging version 8.0 repository lists..."
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list
    sudo apt-get update -y > /dev/null

    # STEP 3.2: Downgrade OS Binaries
    log "Installing version $TARGET_VER binaries..."
    sudo apt-get install -y --allow-downgrades \
        mongodb-org=$TARGET_VER \
        mongodb-org-database=$TARGET_VER \
        mongodb-org-server=$TARGET_VER \
        mongodb-org-shell=$TARGET_VER \
        mongodb-org-mongos=$TARGET_VER \
        mongodb-org-tools=$TARGET_VER >> "$LOG_FILE" 2>&1

    sudo systemctl restart mongod
    log "✅ Rollback to 7.0 complete."
fi
