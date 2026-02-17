#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$BASE_DIR/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ config.env not found at: $CONFIG_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Normalize MODE (removes spaces, CRLF, quotes)
MODE="$(echo "${MODE:-docker}" | tr -d '\r' | tr -d '"' | xargs)"

log() { echo "[PRECHECK] $*"; }
fail() { echo "❌ [PRECHECK] $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

# Detect docker compose command
detect_compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      echo "docker compose"
      return
    fi
  fi
  echo ""
}

log "Running MongoDB production safety precheck..."
log "MODE=$MODE"

require_cmd awk
require_cmd sed
require_cmd grep

# ------------------------------
# Disk check
# ------------------------------
MIN_DISK_GB="${MIN_DISK_GB:-5}"
FREE_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"

[ -n "$FREE_GB" ] || fail "Unable to detect free disk space."

log "Disk free on / : ${FREE_GB} GB (min required: ${MIN_DISK_GB} GB)"

if [ "$FREE_GB" -lt "$MIN_DISK_GB" ]; then
  fail "Not enough disk space. Need at least ${MIN_DISK_GB} GB."
fi

# ------------------------------
# MODE: docker
# ------------------------------
if [ "$MODE" = "docker" ]; then
  require_cmd docker

  COMPOSE_CMD="$(detect_compose)"
  [ -n "$COMPOSE_CMD" ] || fail "Docker compose not found. Install docker-compose OR Docker Compose v2."

  log "Compose command detected: $COMPOSE_CMD"

  [ -f "${COMPOSE_FILE:-}" ] || fail "docker-compose.yml not found at: $COMPOSE_FILE"

  log "Checking docker daemon..."
  docker info >/dev/null 2>&1 || fail "Docker daemon not running or permission denied."

  log "Checking containers exist (mongo1/mongo2/mongo3)..."
  for c in "$MONGO1" "$MONGO2" "$MONGO3"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      log "⚠️ Container $c not running yet (OK if not started)."
    else
      log "✅ Container running: $c"
    fi
  done

  log "Precheck completed for docker mode."
  exit 0
fi

# ------------------------------
# MODE: systemd
# ------------------------------
if [ "$MODE" = "systemd" ]; then
  require_cmd systemctl

  SERVICE_NAME=""
  for s in mongod mongodb; do
    if systemctl list-unit-files | grep -q "^${s}\.service"; then
      SERVICE_NAME="$s"
      break
    fi
  done

  [ -n "$SERVICE_NAME" ] || fail "MongoDB service not found."

  log "Detected service: $SERVICE_NAME"

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "✅ MongoDB service is running."
  else
    log "⚠️ MongoDB service is not active."
  fi

  require_cmd mongosh || log "⚠️ mongosh not found."

  log "Precheck completed for systemd mode."
  exit 0
fi

fail "Invalid MODE value in config.env. Use MODE=docker or MODE=systemd"
