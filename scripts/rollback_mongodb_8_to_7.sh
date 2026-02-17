#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_VER="7.0.14"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
LOG_FILE="/var/log/mongodb-rollback.log"
TS="$(date +'%Y%m%d-%H%M%S')"
BACKUP_DIR="/var/backups/mongodb-rollback-8to7-$TS"
mkdir -p "$BACKUP_DIR"

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
fail() { log "❌ ERROR: $1"; exit 1; }

log "=== 🛡️ Rollback 8.0 → 7.0 START ==="

# STEP 1: FORCE REMOVE VERSION 8 REPO (THE CRITICAL FIX)
log "Purging version 8.0 repository lists..."
sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list
sudo apt-get update -y > /dev/null

# STEP 2: Lower FCV while 8.0 binaries are still present
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi

log "Lowering featureCompatibilityVersion to 7.0..."
if [[ "$MODE" == "docker" ]]; then
    sudo docker exec $MONGO1 mongosh $AUTH_ARGS --eval 'db.adminCommand({setFeatureCompatibilityVersion: "7.0"})' >> "$LOG_FILE" 2>&1 || true
else
    mongosh $AUTH_ARGS --eval 'db.adminCommand({setFeatureCompatibilityVersion: "7.0"})' >> "$LOG_FILE" 2>&1 || true
fi

# STEP 3: Context-Aware Backup
if [[ "$MODE" == "docker" ]]; then
    sudo docker exec $MONGO1 mongodump $AUTH_ARGS --archive > "$BACKUP_DIR/pre_rollback_8.0.archive"
else
    sudo mongodump $AUTH_ARGS --out "$BACKUP_DIR/dump" > /dev/null 2>&1 || true
fi

# STEP 4: Downgrade OS Binaries
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
