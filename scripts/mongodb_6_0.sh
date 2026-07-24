#!/usr/bin/env bash
set -Eeuo pipefail

# TARGET SETTINGS
TARGET_VERSION="6.0"
FULL_VER="6.0.14" # Using a specific stable version
GPG_URL="https://pgp.mongodb.com/server-6.0.asc"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
LOG_FILE="${LOG_FILE:-/var/log/mongodb-upgrade.log}"
BACKUP_DIR="/var/backups/mongodb-$(date +'%Y%m%d-%H%M%S')"
mkdir -p "$BACKUP_DIR"

# Sourcing logging library
LOGGER_SH="$BASE_DIR/modules/logger.sh"
if [ -f "$LOGGER_SH" ]; then
    # shellcheck disable=SC1090
    source "$LOGGER_SH"
else
    log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
    fail() { log "❌ ERROR: $1"; exit 1; }
fi

log "=== MongoDB $TARGET_VERSION install START ==="

# 1. Auth Setup
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    # Use standard admin database for auth arguments
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi

# 2. Context-Aware Backup
if [[ "$MODE" == "docker" ]]; then
    log "Backing up Docker container $MONGO1..."
    if sudo docker exec $MONGO1 mongodump $AUTH_ARGS --archive > "$BACKUP_DIR/backup.archive"; then
        set_log_context "EXPORT_BACKUP_STATUS" "Success"
        log_success "Backup saved to $BACKUP_DIR/backup.archive"
    else
        set_log_context "EXPORT_BACKUP_STATUS" "Failed"
        fail "Backup failed!"
    fi
else
    log "Backing up systemd service..."
    if sudo mongodump $AUTH_ARGS --out "$BACKUP_DIR/dump" >/dev/null 2>&1; then
        set_log_context "EXPORT_BACKUP_STATUS" "Success"
        log_success "Backup saved to $BACKUP_DIR/dump"
    else
        set_log_context "EXPORT_BACKUP_STATUS" "Failed"
        fail "Backup failed!"
    fi
fi

# 3. Upgrade workflow based on MODE
if [[ "$MODE" == "docker" ]]; then
    log "MODE=docker: Upgrading MongoDB replica set using Docker Compose..."
    source "$BASE_DIR/modules/docker_upgrade.sh"
    upgrade_docker_replica_set "$TARGET_VERSION"
    
    # Finalize FCV to 6.0 on the newly elected PRIMARY container
    log "Finalizing FCV to $TARGET_VERSION on PRIMARY ($PRIMARY_NODE)..."
    docker exec "$PRIMARY_NODE" mongosh $AUTH_ARGS --eval "db.adminCommand({setFeatureCompatibilityVersion: '$TARGET_VERSION'})" >>"$LOG_FILE" 2>&1 || log "⚠️ FCV update failed; verify manually."
    log_success "Upgraded replica containers to $TARGET_VERSION."
else
    log "MODE=systemd: Upgrading MongoDB host binaries..."
    # CLEANUP PREVIOUS REPOS
    log "Removing conflicting repository files..."
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-7.0.list

    # Binary Installation (Strictly 6.0)
    log "Configuring MongoDB 6.0 Repository..."
    KEYRING="/usr/share/keyrings/mongodb-6.0.gpg"
    wget -qO - "$GPG_URL" | gpg --dearmor | sudo tee "$KEYRING" >/dev/null
    echo "deb [ signed-by=$KEYRING ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list >/dev/null

    sudo apt-get update -y > /dev/null
    log "Installing binaries for version $FULL_VER..."
    sudo apt-get install -y --allow-downgrades \
        mongodb-org=$FULL_VER \
        mongodb-org-database=$FULL_VER \
        mongodb-org-server=$FULL_VER \
        mongodb-org-shell=$FULL_VER \
        mongodb-org-mongos=$FULL_VER \
        mongodb-org-tools=$FULL_VER >>"$LOG_FILE" 2>&1

    # Restart and Validate
    sudo systemctl restart mongod
    sleep 5
    NEW_VER="$(mongod --version | awk '/db version/ {print $3}')"
    log "Current Version after install: $NEW_VER"

    if [[ "$NEW_VER" == *"$TARGET_VERSION"* ]]; then
        log_success "Installed $NEW_VER"
    else
        fail "Version mismatch! Requested 6.0 but got $NEW_VER"
    fi
fi

log "=== MongoDB $TARGET_VERSION install END ==="
