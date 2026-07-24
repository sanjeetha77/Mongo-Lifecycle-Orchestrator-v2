#!/usr/bin/env bash
# install_mongodb_8_0.sh
# Production-Grade Upgrade Script for MongoDB 8.0
# Handles Docker-to-Host migrations and logical data integrity.

set -Eeuo pipefail

TARGET_VERSION="8.0"

# 1. Load Environment Config
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ config.env not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"
if [[ "${MODE:-docker}" == "docker" ]]; then
    source "$BASE_DIR/modules/docker_upgrade.sh"
fi

# Setup Paths & Logging
LOG_FILE="${LOG_FILE:-/var/log/mongodb-upgrade.log}"
STATE_DIR="${STATE_DIR:-/var/lib/mongodb-upgrade}"
STATE_FILE="$STATE_DIR/state.env"
BACKUP_BASE="${BACKUP_DIR:-/var/backups}"
TS="$(date +'%Y%m%d-%H%M%S')"
BACKUP_DIR="$BACKUP_BASE/mongodb-$TS"

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$BACKUP_DIR"

# Sourcing logging library
LOGGER_SH="$BASE_DIR/modules/logger.sh"
if [ -f "$LOGGER_SH" ]; then
    # shellcheck disable=SC1090
    source "$LOGGER_SH"
else
    log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
    fail() { log "❌ ERROR at line ${BASH_LINENO[0]}: $1"; exit 1; }
fi

trap 'fail "Command '\''${BASH_COMMAND}'\'' failed (exit=$?)"' ERR

log "=== MongoDB 8.0 Production Upgrade START ==="

# 2. Detect Current Environment (Host)
CURRENT_VER="$(mongod --version 2>/dev/null | awk '/db version/ {print $3}' | sed 's/v//' || true)"
log "Detected Host MongoDB Binary: ${CURRENT_VER:-none}"

# 3. Handle Production Backup (Context-Aware)
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase $MONGO_AUTH_DB"
fi

if [[ "$MODE" == "docker" ]]; then
    BACKUP_NODE=$(get_primary_node || echo "$MONGO1")
    log "MODE=docker: Performing logical backup from container $BACKUP_NODE..."
    # Stream backup out of container to host filesystem
    if sudo docker exec "$BACKUP_NODE" mongodump $AUTH_ARGS --archive > "$BACKUP_DIR/production_snapshot.archive"; then
        set_log_context "EXPORT_BACKUP_STATUS" "Success"
        log_success "Docker logical backup saved to $BACKUP_DIR"
    else
        set_log_context "EXPORT_BACKUP_STATUS" "Failed"
        fail "Docker logical backup failed!"
    fi
else
    log "MODE=systemd: Performing host-level backup..."
    if sudo mongodump $AUTH_ARGS --out "$BACKUP_DIR/dump" > /dev/null; then
        set_log_context "EXPORT_BACKUP_STATUS" "Success"
        log_success "Host logical backup saved to $BACKUP_DIR"
    else
        set_log_context "EXPORT_BACKUP_STATUS" "Failed"
        fail "Host logical backup failed!"
    fi
fi

# 4. Prepare for 8.0 (Set FCV 7.0)
log "Ensuring featureCompatibilityVersion is set to 7.0 before binary upgrade..."
if [[ "$MODE" == "docker" ]]; then
    FCV_NODE=$(get_primary_node || echo "$MONGO1")
    sudo docker exec "$FCV_NODE" mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '7.0', confirm: true}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
else
    mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '7.0', confirm: true}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
fi

# 5. Upgrade workflow based on MODE
if [[ "$MODE" == "docker" ]]; then
    log "MODE=docker: Upgrading MongoDB replica set using Docker Compose..."
    source "$BASE_DIR/modules/docker_upgrade.sh"
    upgrade_docker_replica_set "$TARGET_VERSION"
    
    # Finalize FCV to 8.0 on the newly elected PRIMARY container
    log "Finalizing FCV to $TARGET_VERSION on PRIMARY ($PRIMARY_NODE)..."
    docker exec "$PRIMARY_NODE" mongosh $AUTH_ARGS --eval "db.adminCommand({setFeatureCompatibilityVersion: '$TARGET_VERSION', confirm: true})" >>"$LOG_FILE" 2>&1 || log "⚠️ FCV update failed; verify manually."
    log_success "Upgraded replica containers to $TARGET_VERSION."
    
    # Save state for the Master Tool
    {
        echo "LAST_RUN=\"$TS\""
        echo "VERSION=\"$TARGET_VERSION\""
        echo "MODE=\"$MODE\""
        echo "BACKUP_PATH=\"$BACKUP_DIR\""
    } > "$STATE_FILE"
else
    log "MODE=systemd: Upgrading MongoDB host binaries..."
    # OS-Level Binary Installation (Ubuntu/Debian)
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

    # Post-Install Service Cleanup
    log "Sanitizing configuration for version 8.0 compatibility..."
    if [ -f /etc/mongod.conf ]; then
        sudo sed -i '/journal:/,+1d' /etc/mongod.conf
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable mongod
    sudo systemctl restart mongod

    # Final State Capture
    NEW_VER="$(mongod --version 2>/dev/null | awk '/db version/ {print $3}')"
    log "Upgrade Complete. New Version: $NEW_VER"

    # Save state for the Master Tool
    {
        echo "LAST_RUN=\"$TS\""
        echo "VERSION=\"$NEW_VER\""
        echo "MODE=\"$MODE\""
        echo "BACKUP_PATH=\"$BACKUP_DIR\""
    } > "$STATE_FILE"
fi

log "=== MongoDB 8.0 Production Upgrade END ==="
