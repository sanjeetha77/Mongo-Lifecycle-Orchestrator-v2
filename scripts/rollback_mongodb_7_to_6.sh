#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_VER="6.0.14"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
LOG_FILE="/var/log/mongodb-rollback.log"
TS="$(date +'%Y%m%d-%H%M%S')"
BACKUP_DIR="/var/backups/mongodb-rollback-7to6-$TS"
mkdir -p "$BACKUP_DIR"

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
fail() { log "❌ ERROR: $1"; exit 1; }

log "=== 🛡️ Rollback 7.0 → 6.0 START ==="

# STEP 1: PURGE HIGHER REPOS
log "Purging higher version repositories (7.0, 8.0)..."
sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list
sudo rm -f /etc/apt/sources.list.d/mongodb-org-7.0.list
sudo apt-get update -y > /dev/null

# STEP 2: Lower FCV
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi

log "Lowering FCV to 6.0..."
if [[ "$MODE" == "docker" ]]; then
    sudo docker exec $MONGO1 mongosh $AUTH_ARGS --eval 'db.adminCommand({setFeatureCompatibilityVersion: "6.0"})' >> "$LOG_FILE" 2>&1 || true
else
    mongosh $AUTH_ARGS --eval 'db.adminCommand({setFeatureCompatibilityVersion: "6.0"})' >> "$LOG_FILE" 2>&1 || true
fi

# STEP 3: Install 6.0 Specific Binaries
log "Installing version $TARGET_VER..."
GPG_URL="https://pgp.mongodb.com/server-6.0.asc"
KEYRING="/usr/share/keyrings/mongodb-6.0.gpg"
wget -qO - "$GPG_URL" | gpg --dearmor | sudo tee "$KEYRING" >/dev/null
echo "deb [ signed-by=$KEYRING ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list >/dev/null

sudo apt-get update -y > /dev/null
sudo apt-get install -y --allow-downgrades \
    mongodb-org=$TARGET_VER \
    mongodb-org-database=$TARGET_VER \
    mongodb-org-server=$TARGET_VER \
    mongodb-org-shell=$TARGET_VER \
    mongodb-org-mongos=$TARGET_VER \
    mongodb-org-tools=$TARGET_VER >> "$LOG_FILE" 2>&1

sudo systemctl restart mongod
log "✅ Rollback to 6.0 complete."
