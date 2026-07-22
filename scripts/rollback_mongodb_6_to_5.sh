#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_VER="5.0.31"

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
if [[ "${MODE:-docker}" == "docker" ]]; then
    source "$BASE_DIR/modules/docker_upgrade.sh"
fi
LOG_FILE="/var/log/mongodb-rollback.log"
TS="$(date +'%Y%m%d-%H%M%S')"
BACKUP_DIR="/var/backups/mongodb-rollback-6to5-$TS"
mkdir -p "$BACKUP_DIR"

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
fail() { log "❌ ERROR: $1"; exit 1; }

log "=== 🛡️ Rollback 6.0 → 5.0 START ==="

# STEP 1: Lower FCV
AUTH_ARGS=""
if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    AUTH_ARGS="--username $MONGO_ADMIN_USER --password $MONGO_ADMIN_PASS --authenticationDatabase admin"
fi
log "Lowering FCV to 5.0..."
if [[ "$MODE" == "docker" ]]; then
    FCV_NODE=$(get_primary_node || echo "$MONGO1")
    sudo docker exec "$FCV_NODE" mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '5.0'}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
else
    mongosh $AUTH_ARGS --eval "const res = db.adminCommand({setFeatureCompatibilityVersion: '5.0'}); if (!res.ok) { print(JSON.stringify(res)); quit(1); }"
fi

# STEP 2: Rollback execution based on MODE
if [[ "$MODE" == "docker" ]]; then
    log "MODE=docker: Recreating Docker containers with target version 5.0..."
    source "$BASE_DIR/modules/docker_upgrade.sh"
    upgrade_docker_replica_set "5.0" "rollback"
    log "✅ Rollback to 5.0 complete in Docker."
else
    log "MODE=systemd: Downgrading MongoDB host binaries..."
    # STEP 2.1: PURGE ALL REPOS
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    sudo apt-get update -y > /dev/null

    # STEP 2.2: libssl1.1 Workaround (Noble/Jammy)
    CODENAME=$(lsb_release -sc)
    if [[ "$CODENAME" =~ (noble|jammy) ]]; then
        log "Ensuring libssl1.1 is available..."
        echo "deb http://security.ubuntu.com/ubuntu focal-security main" | sudo tee /etc/apt/sources.list.d/focal-security.list >/dev/null
        sudo apt-get update -y > /dev/null
        sudo apt-get install -y libssl1.1 > /dev/null
    fi

    # STEP 2.3: Install 5.0 Specific Binaries
    GPG_URL="https://pgp.mongodb.com/server-5.0.asc"
    KEYRING="/usr/share/keyrings/mongodb-5.0.gpg"
    wget -qO - "$GPG_URL" | gpg --dearmor | sudo tee "$KEYRING" >/dev/null
    echo "deb [ signed-by=$KEYRING ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list >/dev/null

    sudo apt-get update -y > /dev/null
    sudo apt-get install -y --allow-downgrades \
        mongodb-org=$TARGET_VER \
        mongodb-org-database=$TARGET_VER \
        mongodb-org-server=$TARGET_VER \
        mongodb-org-shell=$TARGET_VER \
        mongodb-org-mongos=$TARGET_VER \
        mongodb-org-tools=$TARGET_VER >> "$LOG_FILE" 2>&1

    sudo systemctl restart mongod
    log "✅ Rollback to 5.0 complete."
fi
