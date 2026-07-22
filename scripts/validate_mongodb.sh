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

log() { echo "[VALIDATE] $*"; }
fail() { echo "❌ [VALIDATE] $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_cmd awk
require_cmd grep
require_cmd sed

MODE="${MODE:-docker}"
RS_NAME="${RS_NAME:-rs0}"

AUTH_ENABLED="${AUTH_ENABLED:-true}"
MONGO_ADMIN_USER="${MONGO_ADMIN_USER:-admin}"
MONGO_ADMIN_PASS="${MONGO_ADMIN_PASS:-Admin123}"
MONGO_AUTH_DB="${MONGO_AUTH_DB:-admin}"

VALIDATE_WRITE_TEST="${VALIDATE_WRITE_TEST:-false}"
VALIDATE_LOG_CHECK="${VALIDATE_LOG_CHECK:-true}"
MAX_LOG_ERROR_LINES="${MAX_LOG_ERROR_LINES:-30}"

# ------------------------------
# Helper: run mongosh command
# ------------------------------
run_mongosh() {
  local target="$1" # host:port OR docker container name
  local js="$2"

  if [ "$MODE" = "docker" ]; then
    if [ "$AUTH_ENABLED" = "true" ]; then
      docker exec "$target" mongosh --quiet \
        -u "$MONGO_ADMIN_USER" -p "$MONGO_ADMIN_PASS" --authenticationDatabase "$MONGO_AUTH_DB" \
        --eval "$js"
    else
      docker exec "$target" mongosh --quiet --eval "$js"
    fi
  else
    # systemd / local
    if [ "$AUTH_ENABLED" = "true" ]; then
      mongosh --quiet \
        -u "$MONGO_ADMIN_USER" -p "$MONGO_ADMIN_PASS" --authenticationDatabase "$MONGO_AUTH_DB" \
        --eval "$js"
    else
      mongosh --quiet --eval "$js"
    fi
  fi
}

# ------------------------------
# MODE: docker validation
# ------------------------------
if [ "$MODE" = "docker" ]; then
  require_cmd docker

  log "Validating MongoDB Docker ReplicaSet..."
  log "ReplicaSet name: $RS_NAME"

  # ------------------------------
  # Detect running containers
  # ------------------------------
  RUNNING_NODES=()
  for c in "$MONGO1" "$MONGO2" "$MONGO3"; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then
      RUNNING_NODES+=("$c")
    fi
  done

  if [ "${#RUNNING_NODES[@]}" -eq 0 ]; then
    fail "No MongoDB containers are running. Start docker compose first."
  fi

  log "Running nodes detected: ${RUNNING_NODES[*]}"

  # Pick first running node as seed
  PRIMARY_NODE="${RUNNING_NODES[0]}"
  log "Using seed node for validation: $PRIMARY_NODE"

  # 1) Ping check
  log "Checking ping..."
  run_mongosh "$PRIMARY_NODE" 'db.adminCommand({ping:1}).ok' | grep -q "1" \
    || fail "Ping failed on $PRIMARY_NODE"
  log "✅ Ping successful."

  # 2) ReplicaSet health
  log "Checking ReplicaSet status..."
  RS_OK="$(run_mongosh "$PRIMARY_NODE" "rs.status().ok" | tr -d '\r\n ')"
  [ "$RS_OK" = "1" ] || fail "ReplicaSet not healthy (rs.status().ok != 1)"
  log "✅ ReplicaSet is healthy."

  # 3) Members count
  log "Checking ReplicaSet member count..."
  MEMBER_COUNT="$(run_mongosh "$PRIMARY_NODE" "rs.status().members.length" | tr -d '\r\n ')"
  log "Replica members detected: $MEMBER_COUNT"
  [ "$MEMBER_COUNT" -ge 3 ] || fail "ReplicaSet should have 3 members, found: $MEMBER_COUNT"
  log "✅ Replica member count OK."

  # 4) Check each member state
  log "Checking each member health..."
  for c in "$MONGO1" "$MONGO2" "$MONGO3"; do
    if docker ps --format '{{.Names}}' | grep -qx "$c"; then
      run_mongosh "$c" 'db.adminCommand({ping:1}).ok' | grep -q "1" \
        || fail "Ping failed on member: $c"
      log "✅ Member OK: $c"
    else
      fail "Replica member container is NOT running: $c"
    fi
  done

  # 5) FCV check
  log "Checking featureCompatibilityVersion..."
  FCV="$(run_mongosh "$PRIMARY_NODE" 'db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version' | tr -d '\r\n "')"
  log "Current FCV: $FCV"

  if [ -z "$FCV" ] || [ "$FCV" = "null" ]; then
    fail "FCV could not be detected."
  fi
  log "✅ FCV detected."

  # 5b) Version validation check
  log "Checking Docker image and running MongoDB version..."
  
  if [ -f "$COMPOSE_FILE" ]; then
    EXPECTED_VER=$(grep -i 'image:' "$COMPOSE_FILE" | head -n 1 | awk -F'mongo:' '{print $2}' | tr -d ' "\r\n')
  else
    EXPECTED_VER="unknown"
  fi

  # Query version from primary node running container
  CURRENT_VER=$(docker exec "$PRIMARY_NODE" mongod --version 2>/dev/null | awk '/db version/ {print $3}' | sed 's/v//' | tr -d '\r\n[:space:]')
  if [ -z "$CURRENT_VER" ]; then
    # Fallback to querying db.version()
    CURRENT_VER=$(run_mongosh "$PRIMARY_NODE" "db.version()" | tr -d '\r\n "')
  fi

  log "Expected : $EXPECTED_VER"
  log "Current  : $CURRENT_VER"

  if [ "$EXPECTED_VER" = "unknown" ]; then
    fail "Could not determine Expected Version from $COMPOSE_FILE."
  fi
  if [ -z "$CURRENT_VER" ]; then
    fail "Could not detect Current Version from running container $PRIMARY_NODE."
  fi

  # Check if CURRENT_VER starts with EXPECTED_VER (e.g. "8.0.26" starts with "8.0")
  if [[ "$CURRENT_VER" != "$EXPECTED_VER"* ]]; then
    log "❌ Version mismatch detected."
    fail "Version mismatch detected. Validation Failed."
  fi
  log "✅ Version check passed."

  # 6) Optional write test
  if [ "$VALIDATE_WRITE_TEST" = "true" ]; then
    log "Running write test..."
    run_mongosh "$PRIMARY_NODE" '
      db.getSiblingDB("validation_db").t.insertOne({ok:true,ts:new Date()});
      db.getSiblingDB("validation_db").t.findOne({ok:true}) != null ? 1 : 0
    ' | grep -q "1" || fail "Write test failed."
    log "✅ Write test successful."
  else
    log "Skipping write test (VALIDATE_WRITE_TEST=false)."
  fi

  # 7) Log check
  if [ "$VALIDATE_LOG_CHECK" = "true" ]; then
    log "Checking docker logs for fatal errors..."
    ERR_LINES="$(docker logs "$PRIMARY_NODE" 2>&1 | grep -Ei 'fatal|panic|segmentation|wiredtiger error' | tail -n "$MAX_LOG_ERROR_LINES" || true)"
    if [ -n "$ERR_LINES" ]; then
      echo "$ERR_LINES"
      fail "Detected fatal/panic errors in MongoDB logs."
    fi
    log "✅ No fatal log patterns found."
  else
    log "Skipping log check (VALIDATE_LOG_CHECK=false)."
  fi

  log "🎉 VALIDATION PASSED (docker replicaSet)."
  exit 0
fi

# ------------------------------
# MODE: systemd validation
# ------------------------------
if [ "$MODE" = "systemd" ]; then
  require_cmd mongosh
  require_cmd systemctl

  SERVICE_NAME=""
  for s in mongod mongodb; do
    if systemctl list-unit-files | grep -q "^${s}\.service"; then
      SERVICE_NAME="$s"
      break
    fi
  done
  [ -n "$SERVICE_NAME" ] || fail "MongoDB service not found."

  log "Validating MongoDB systemd service: $SERVICE_NAME"

  systemctl is-active --quiet "$SERVICE_NAME" || fail "MongoDB service is not active."

  log "✅ Service is running."

  log "Checking ping..."
  run_mongosh "local" 'db.adminCommand({ping:1}).ok' | grep -q "1" \
    || fail "Ping failed on localhost."

  log "✅ Ping OK."

  log "Checking FCV..."
  FCV="$(run_mongosh "local" 'db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version' | tr -d '\r\n "')"
  log "Current FCV: $FCV"
  [ -n "$FCV" ] || fail "FCV could not be detected."

  log "🎉 VALIDATION PASSED (systemd)."
  exit 0
fi

fail "Invalid MODE in config.env: $MODE"
