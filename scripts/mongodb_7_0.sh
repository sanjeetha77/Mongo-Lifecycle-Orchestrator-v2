#!/usr/bin/env bash
set -Eeuo pipefail

# TARGET SETTINGS
TARGET_VERSION="7.0"
FULL_VER="7.0.14" 
GPG_URL="https://pgp.mongodb.com/server-7.0.asc"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
LOG_FILE="${LOG_FILE:-/var/log/mongodb-upgrade.log}"
BACKUP_DIR="/var/backups/mongodb-$(date +'%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP_DIR"

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
fail() { log "❌ ERROR: $1"; exit 1; }

log "=== MongoDB $TARGET_VERSION install START ==="

# 1. REPOSITORY SHIELD (The fix for version collision)
log "Cleaning conflicting repository files to ensure version pinning..."
sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list
sudo rm -f /etc/apt/sources.list.d/mongodb-org-6.0.list
sudo rm -f /etc/apt/sources.list.d/mongodb-org-5.0.list

# 2. Auth Setup
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi

# 3. Pre-Upgrade FCV check (Mandatory logic for 6.0 -> 7.0)
log "Setting FCV to 6.0 to prepare for 7.0 upgrade..."
if [[ "$MODE" == "docker" ]]; then
    sudo docker exec $MONGO1 mongosh $AUTH_ARGS --eval "db.adminCommand({setFeatureCompatibilityVersion: '6.0'})" >/dev/null 2>&1 || true
else
    mongosh $AUTH_ARGS --eval "db.adminCommand({setFeatureCompatibilityVersion: '6.0'})" >/dev/null 2>&1 || true
fi

# 4. Context-Aware Backup
if [[ "$MODE" == "docker" ]]; then
    log "Backing up Docker container $MONGO1..."
    sudo docker exec $MONGO1 mongodump $AUTH_ARGS --archive > "$BACKUP_DIR/backup.archive"
else
    log "Backing up systemd service..."
    sudo mongodump $AUTH_ARGS --out "$BACKUP_DIR/dump" >/dev/null 2>&1 || true
fi

# 5. Binary Installation (Strictly 7.0)
log "Configuring MongoDB 7.0 Repository..."
KEYRING="/usr/share/keyrings/mongodb-7.0.gpg"
wget -qO - "$GPG_URL" | gpg --dearmor | sudo tee "$KEYRING" >/dev/null
echo "deb [ signed-by=$KEYRING ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list >/dev/null

sudo apt-get update -y > /dev/null
log "Installing binaries for version $FULL_VER..."
sudo apt-get install -y --allow-downgrades \
    mongodb-org=$FULL_VER \
    mongodb-org-database=$FULL_VER \
    mongodb-org-server=$FULL_VER \
    mongodb-org-shell=$FULL_VER \
    mongodb-org-mongos=$FULL_VER \
    mongodb-org-tools=$FULL_VER >>"$LOG_FILE" 2>&1

# 6. Restart and Finalize FCV
sudo systemctl restart mongod
sleep 5
NEW_VER="$(mongod --version | awk '/db version/ {print $3}')"
log "Current Version after install: $NEW_VER"

if [[ "$NEW_VER" == *"$TARGET_VERSION"* ]]; then
    log "Finalizing FCV to 7.0..."
    mongosh $AUTH_ARGS --eval "db.adminCommand({setFeatureCompatibilityVersion: '7.0'})" >>"$LOG_FILE" 2>&1 || log "⚠️ FCV update failed; verify manually."
    log "✅ Success: Installed $NEW_VER"
else
    fail "Version mismatch! Requested 7.0 but got $NEW_VER"
fi

log "=== MongoDB $TARGET_VERSION install END ==="
