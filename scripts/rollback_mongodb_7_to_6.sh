#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_VER="6.0.14"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
if [[ "${MODE:-docker}" == "docker" ]]; then
    source "$BASE_DIR/modules/docker_upgrade.sh"
fi
LOG_FILE="${LOG_FILE:-/var/log/mongodb-rollback.log}"
# Sourcing logging library
LOGGER_SH="$BASE_DIR/modules/logger.sh"
if [ -f "$LOGGER_SH" ]; then
    # shellcheck disable=SC1090
    source "$LOGGER_SH"
else
    log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
    fail() { log "❌ ERROR: $1"; exit 1; }
fi

TS="$(date +'%Y%m%d-%H%M%S')"
BACKUP_DIR="/var/backups/mongodb-rollback-7to6-$TS"
mkdir -p "$BACKUP_DIR"

log "=== 🛡️ Rollback 7.0 → 6.0 START ==="

# Set rollback triggered context
set_log_context "EXPORT_ROLLBACK_TRIGGERED" "Yes"

# STEP 1: Lower FCV
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi

log "Lowering FCV to 6.0..."
if [[ "$MODE" == "docker" ]]; then
    FCV_NODE=$(get_primary_node || echo "$MONGO1")
    sudo docker exec "$FCV_NODE" mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '6.0', confirm: true}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
else
    mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '6.0',confirm: true}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
fi

# STEP 2: Rollback execution based on MODE
if [[ "$MODE" == "docker" ]]; then
    log "MODE=docker: Recreating Docker containers with target version 6.0..."
    source "$BASE_DIR/modules/docker_upgrade.sh"
    upgrade_docker_replica_set "6.0" "rollback"
    log_success "Rollback to 6.0 complete in Docker."
else
    log "MODE=systemd: Downgrading MongoDB host binaries..."
    # STEP 2.1: PURGE HIGHER REPOS
    log "Purging higher version repositories (7.0, 8.0)..."
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-7.0.list
    sudo apt-get update -y > /dev/null

    # STEP 2.2: Install 6.0 Specific Binaries
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
    log_success "Rollback to 6.0 complete."
fi
