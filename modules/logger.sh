#!/usr/bin/env bash
# modules/logger.sh
# Shared logging library for MongoDB Lifecycle Orchestrator

# Global variables for log state
LOG_DIR="/var/log/mongodb-upgrade"
HISTORY_LOG="$LOG_DIR/history.log"
RUNTIME_CONTEXT_FILE="/var/lib/mongodb-upgrade/runtime_context.env"

# Automatically create log and state directories
sudo mkdir -p "$LOG_DIR" "/var/lib/mongodb-upgrade"
sudo chmod 777 "$LOG_DIR" "/var/lib/mongodb-upgrade" 2>/dev/null || true

# Helper to format timestamp
get_timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

# Load the shared logging context if it exists
if [ -f "$RUNTIME_CONTEXT_FILE" ]; then
    # Sourcing it allows sub-processes to automatically inherit LOG_FILE, EXEC_ID, etc.
    # shellcheck disable=SC1090
    source "$RUNTIME_CONTEXT_FILE"
fi

# Logger functions
log_info() {
    local msg="$*"
    local ts=$(get_timestamp)
    echo -e "[$ts] [INFO] $msg" | sudo tee -a "${LOG_FILE}" >/dev/null
    echo -e "[$ts] [INFO] $msg"
}

log_warn() {
    local msg="$*"
    local ts=$(get_timestamp)
    echo -e "[$ts] [WARN] $msg" | sudo tee -a "${LOG_FILE}" >/dev/null
    echo -e "[$ts] [WARN] $msg"
}

log_error() {
    local msg="$*"
    local ts=$(get_timestamp)
    echo -e "[$ts] [ERROR] $msg" | sudo tee -a "${LOG_FILE}" >/dev/null
    echo -e "[$ts] [ERROR] $msg" >&2
}

log_success() {
    local msg="$*"
    local ts=$(get_timestamp)
    echo -e "[$ts] [SUCCESS] $msg" | sudo tee -a "${LOG_FILE}" >/dev/null
    echo -e "[$ts] [SUCCESS] $msg"
}

# Backwards compatibility: Map standard print calls to structured logs
log() {
    log_info "$*"
}

fail() {
    log_error "$*"
    exit 1
}

# Helper to update context keys dynamically
set_log_context() {
    local key="$1"
    local value="$2"
    export "$key"="$value"
    # Ensure context directory exists
    sudo mkdir -p "/var/lib/mongodb-upgrade"
    if [ -f "$RUNTIME_CONTEXT_FILE" ]; then
        # Remove existing line matching the key to avoid duplication
        sudo sed -i "/export $key=/d" "$RUNTIME_CONTEXT_FILE"
    fi
    echo "export $key=\"$value\"" | sudo tee -a "$RUNTIME_CONTEXT_FILE" >/dev/null
}

# Initialize a specific log execution file
init_logging() {
    local operation="$1"     # upgrade, rollback, validate, precheck
    local src_ver="${2:-}"
    local target_ver="${3:-}"
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

    # If LOG_FILE is already set and exported in environment, use it
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        return 0
    fi

    # Reset/clean existing runtime context
    sudo rm -f "$RUNTIME_CONTEXT_FILE"

    # Generate descriptive Execution ID (e.g., UP-20260724-103542)
    local prefix="EXEC"
    case "$operation" in
        upgrade)  prefix="UP" ;;
        rollback) prefix="RB" ;;
        validate) prefix="VAL" ;;
        precheck) prefix="PRE" ;;
    esac
    local exec_id="${prefix}-$(date +"%Y%m%d-%H%M%S")"
    
    local filename=""
    case "$operation" in
        upgrade)
            filename="upgrade_${src_ver:-unknown}_to_${target_ver:-unknown}_${timestamp}.log"
            ;;
        rollback)
            filename="rollback_${src_ver:-unknown}_to_${target_ver:-unknown}_${timestamp}.log"
            ;;
        validate)
            filename="validate_${src_ver:-unknown}_${timestamp}.log"
            ;;
        precheck)
            filename="precheck_${timestamp}.log"
            ;;
        *)
            filename="operation_${timestamp}.log"
            ;;
    esac

    local log_file_path="$LOG_DIR/$filename"
    sudo touch "$log_file_path"
    sudo chmod 666 "$log_file_path" 2>/dev/null || true

    # Save to initial runtime context
    set_log_context "LOG_FILE" "$log_file_path"
    set_log_context "EXEC_ID" "$exec_id"
    set_log_context "OP_START_EPOCH" "$(date +%s)"
    set_log_context "OP_START_TIME_STR" "$(get_timestamp)"
    set_log_context "OP_TYPE" "$operation"
    set_log_context "OP_SRC_VER" "$src_ver"
    set_log_context "OP_TARGET_VER" "$target_ver"
}

# Helper to auto-detect current MongoDB version
detect_current_version() {
    # Check if we have source version in config or runtime context
    if [ -n "${OP_SRC_VER:-}" ] && [ "$OP_SRC_VER" != "unknown" ]; then
        echo "$OP_SRC_VER"
        return
    fi
    
    local ver=""
    if [ "${MODE:-docker}" = "docker" ]; then
        if [ -n "${COMPOSE_FILE:-}" ] && [ -f "$COMPOSE_FILE" ]; then
            ver=$(grep -i 'image:' "$COMPOSE_FILE" | head -n 1 | awk -F'mongo:' '{print $2}' | tr -d ' "\r\n')
        fi
        if [ -z "$ver" ] && [ -n "${MONGO1:-}" ]; then
            # Query running container mongo1
            if docker ps --format '{{.Names}}' | grep -qx "${MONGO1}"; then
                ver=$(docker exec "${MONGO1}" mongod --version 2>/dev/null | awk '/db version/ {print $3}' | sed 's/v//' | tr -d '\r\n[:space:]')
            fi
        fi
    else
        ver=$(mongod --version 2>/dev/null | awk '/db version/ {print $3}' | sed 's/v//' | tr -d '\r\n[:space:]' || true)
    fi
    echo "${ver:-unknown}"
}

# Generate final execution summary
write_execution_summary() {
    # Reload context to get final values updated by other sub-scripts
    if [ -f "$RUNTIME_CONTEXT_FILE" ]; then
        # shellcheck disable=SC1090
        source "$RUNTIME_CONTEXT_FILE"
    fi

    # Ensure LOG_FILE and start epoch are set
    if [ -z "${LOG_FILE:-}" ] || [ -z "${OP_START_EPOCH:-}" ]; then
        return 0
    fi

    local end_epoch=$(date +%s)
    local end_time_str=$(get_timestamp)
    local duration=$((end_epoch - OP_START_EPOCH))
    
    # Read status variables or set defaults
    local exec_id="${EXEC_ID:-unknown}"
    local op="${OP_TYPE:-unknown}"
    local src="${OP_SRC_VER:-unknown}"
    local target="${OP_TARGET_VER:-unknown}"
    local mode="${MODE:-docker}"
    local backup_status="${EXPORT_BACKUP_STATUS:-Skipped}"
    local val_status="${EXPORT_VAL_STATUS:-Skipped}"
    local rollback_triggered="${EXPORT_ROLLBACK_TRIGGERED:-No}"
    local final_status="${EXPORT_FINAL_STATUS:-Success}"

    # Format execution summary
    local summary="
==================================================
               EXECUTION SUMMARY
==================================================
Execution ID:       $exec_id
Operation:          $op
Previous Version:   $src
Target Version:     $target
Replica Mode:       $mode
Start Time:         $OP_START_TIME_STR
End Time:           $end_time_str
Total Duration:     ${duration}s
Backup Status:      $backup_status
Validation Status:  $val_status
Rollback Triggered: $rollback_triggered
Final Status:       $final_status
Log File:           $LOG_FILE
=================================================="

    # Print summary to console and log file
    echo "$summary"
    echo "$summary" | sudo tee -a "$LOG_FILE" >/dev/null

    # Write to history.log
    # Format: Timestamp | Execution ID | Operation | Source | Target | Duration | Status | Logfile
    local history_line="$(get_timestamp) | EXEC_ID: $exec_id | OP: $op | SRC: $src | TGT: $target | DUR: ${duration}s | STATUS: $final_status | LOG: $(basename "$LOG_FILE")"
    echo "$history_line" | sudo tee -a "$HISTORY_LOG" >/dev/null

    # Clean up context file
    sudo rm -f "$RUNTIME_CONTEXT_FILE"
}
