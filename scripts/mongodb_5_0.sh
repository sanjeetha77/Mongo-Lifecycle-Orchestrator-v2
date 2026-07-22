#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/config.env"
LOG_FILE="${LOG_FILE:-/var/log/mongodb-upgrade.log}"
TS="$(date +'%Y%m%d-%H%M%S')"

log() { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOG_FILE"; }
fail() { log "❌ ERROR: $1"; exit 1; }

log "=== MongoDB 5.0 Baseline Setup START ==="

if [[ "${MODE:-docker}" == "docker" ]]; then
    log "MODE=docker: Upgrading/Setting up Docker MongoDB containers..."
    source "$BASE_DIR/modules/docker_upgrade.sh"
    upgrade_docker_replica_set "5.0"
    log "✅ MongoDB 5.0 Docker upgrade completed."
else
    log "MODE=systemd: Setting up MongoDB on Host..."
    # 1. Dependency Fix for Ubuntu 24.04/22.04
    CODENAME=$(lsb_release -sc)
    if [[ "$CODENAME" =~ (noble|jammy) ]]; then
        log "Installing libssl1.1 dependency for legacy support..."
        echo "deb http://security.ubuntu.com/ubuntu focal-security main" | sudo tee /etc/apt/sources.list.d/focal-security.list >/dev/null
        sudo apt-get update -y > /dev/null
        sudo apt-get install -y libssl1.1 > /dev/null
    fi

    # 2. Install Binaries
    wget -qO - https://pgp.mongodb.com/server-5.0.asc | gpg --dearmor | sudo tee /usr/share/keyrings/mongodb-5.0.gpg >/dev/null
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-5.0.gpg ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list >/dev/null
    sudo apt-get update -y > /dev/null
    sudo apt-get install -y mongodb-org=5.0.31 mongodb-org-database=5.0.31 mongodb-org-server=5.0.31 mongodb-org-shell=5.0.31 mongodb-org-mongos=5.0.31 mongodb-org-tools=5.0.31

    # 3. Start Service
    sudo systemctl enable mongod && sudo systemctl restart mongod
    log "✅ MongoDB 5.0 Installed on Host."
fi

log "=== MongoDB 5.0 Setup END ==="
