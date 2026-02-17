#!/usr/bin/env bash
# install_mongodb_8_0.sh
# Production-Grade Upgrade Script for MongoDB 8.0
# Handles Docker-to-Host migrations and logical data integrity.

set -Eeuo pipefail

# 1. Load Environment Config
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ config.env not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Setup Paths & Logging
LOG_FILE="${LOG_FILE:-/var/log/mongodb-upgrade.log}"
STATE_DIR="${STATE_DIR:-/var/lib/mongodb-upgrade}"
STATE_FILE="$STATE_DIR/state.env"
BACKUP_BASE="${BACKUP_DIR:-/var/backups}"
TS="$(date +'%Y%m%d-%H%M%S')"
BACKUP_DIR="$BACKUP_BASE/mongodb-$TS"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$BACKUP_DIR"

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
fail() { log "❌ ERROR at line ${BASH_LINENO[0]}: $1"; exit 1; }

trap 'fail "Command '\''${BASH_COMMAND}'\'' failed (exit=$?)"' ERR

log "=== MongoDB 8.0 Production Upgrade START ==="

# 2. Detect Current Environment
CURRENT_VER="$(mongod --version 2>/dev/null | awk '/db version/ {print $3}' | sed 's/v//' || true)"
log "Detected Host MongoDB Binary: ${CURRENT_VER:-none}"

# 3. Handle Production Backup (Context-Aware)
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase $MONGO_AUTH_DB"
fi

if [[ "$MODE" == "docker" ]]; then
    log "MODE=docker: Performing logical backup from container $MONGO1..."
    # Stream backup out of container to host filesystem
    sudo docker exec $MONGO1 mongodump $AUTH_ARGS --archive > "$BACKUP_DIR/production_snapshot.archive"
    log "✅ Docker logical backup saved to $BACKUP_DIR"
else
    log "MODE=systemd: Performing host-level backup..."
    sudo mongodump $AUTH_ARGS --out "$BACKUP_DIR/dump" > /dev/null
    log "✅ Host logical backup saved to $BACKUP_DIR"
fi

# 4. Prepare for 8.0 (Set FCV 7.0)
log "Ensuring featureCompatibilityVersion is set to 7.0 before binary upgrade..."
if [[ "$MODE" == "docker" ]]; then
    sudo docker exec $MONGO1 mongosh $AUTH_ARGS --eval 'db.adminCommand({setFeatureCompatibilityVersion: "7.0"})' >> "$LOG_FILE" 2>&1 || log "⚠️ FCV already set or container busy."
else
    mongosh $AUTH_ARGS --eval 'db.adminCommand({setFeatureCompatibilityVersion: "7.0"})' >> "$LOG_FILE" 2>&1 || log "⚠️ FCV already set or service stopped."
fi

# 5. OS-Level Binary Installation (Ubuntu/Debian)
log "Configuring MongoDB 8.0 Repositories..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y > /dev/null

# Setup GPG and Repo for 8.0
GPG_URL="https://pgp.mongodb.com/server-8.0.asc"
KEYRING="/usr/share/keyrings/mongodb-8.0.gpg"
wget -qO - "$GPG_URL" | gpg --dearmor | sudo tee "$KEYRING" >/dev/null
echo "deb [ signed-by=$KEYRING ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list >/dev/null

log "Installing MongoDB 8.0.x binaries..."
sudo apt-get update -y > /dev/null
sudo apt-get install -y mongodb-org >> "$LOG_FILE" 2>&1

# 6. Post-Install Service Cleanup
log "Sanitizing configuration for version 8.0 compatibility..."
if [ -f /etc/mongod.conf ]; then
    sudo sed -i '/journal:/,+1d' /etc/mongod.conf
fi

sudo systemctl daemon-reload
sudo systemctl enable mongod
sudo systemctl restart mongod

# 7. Final State Capture
NEW_VER="$(mongod --version 2>/dev/null | awk '/db version/ {print $3}')"
log "Upgrade Complete. New Version: $NEW_VER"

# Save state for the Master Tool
{
    echo "LAST_RUN=\"$TS\""
    echo "VERSION=\"$NEW_VER\""
    echo "MODE=\"$MODE\""
    echo "BACKUP_PATH=\"$BACKUP_DIR\""
} > "$STATE_FILE"

log "=== MongoDB 8.0 Production Upgrade END ==="
