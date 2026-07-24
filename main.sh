#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
VALIDATE_SCRIPT="$SCRIPTS_DIR/validate_mongodb.sh"
PRECHECK_SCRIPT="$SCRIPTS_DIR/precheck_mongodb.sh"
CONFIG_FILE="$BASE_DIR/config.env"
LOGGER_SH="$BASE_DIR/modules/logger.sh"

if [ -f "$LOGGER_SH" ]; then
    # shellcheck disable=SC1090
    source "$LOGGER_SH"
fi

cleanup_and_summary() {
    local exit_code=$?
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        # If EXPORT_FINAL_STATUS wasn't set or is not Success, ensure it registers as Failed
        if [ "${EXPORT_FINAL_STATUS:-}" != "Success" ]; then
            set_log_context "EXPORT_FINAL_STATUS" "Failed"
        fi
        write_execution_summary
    fi
}
trap cleanup_and_summary EXIT

# ------------------------------
# 1. Dependency & Environment Check
# ------------------------------
check_dependencies() {
    echo "🔍 Performing Pre-Flight Dependency Checks..."
    local missing=0
    
    # Check for core binaries
    for cmd in docker mongosh openssl wget gpg; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "❌ Missing dependency: $cmd"
            missing=1
        fi
    done

    # Check for config file
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ config.env not found! Please create it from the template."
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        echo "🛑 Environment is not ready. Please install missing tools and try again."
        exit 1
    fi
    echo "✅ Environment Ready."
}

# ------------------------------
# 2. Validation + Auto Rollback
# ------------------------------
run_validation_or_rollback() {
    local rollback_script="$1"
    echo ""
    echo "=============================================="
    echo " Running MongoDB Validation..."
    echo "=============================================="
    set +e
    sudo bash -c "$VALIDATE_SCRIPT </dev/tty"
    VAL_RC=$?
    set -e

    if [ $VAL_RC -eq 0 ]; then
        echo -e "\n✅ VALIDATION PASSED!\n"
        set_log_context "EXPORT_VAL_STATUS" "Success"
        return 0
    fi

    echo -e "\n❌ VALIDATION FAILED!"
    set_log_context "EXPORT_VAL_STATUS" "Failed"
    echo "⚠️ Auto rollback will start now..."
    set_log_context "EXPORT_ROLLBACK_TRIGGERED" "Yes"
    sudo "$rollback_script"
    
    echo "=============================================="
    echo " Running Validation After Rollback..."
    echo "=============================================="
    set +e
    sudo bash -c "$VALIDATE_SCRIPT </dev/tty"
    VAL_AFTER_RC=$?
    set -e
    
    if [ $VAL_AFTER_RC -eq 0 ]; then
        set_log_context "EXPORT_VAL_STATUS" "Success after Rollback"
    else
        set_log_context "EXPORT_VAL_STATUS" "Failed after Rollback"
    fi
    echo -e "\n⚠️ Rollback Completed (Check logs).\n"
    return 1
}

# ------------------------------
# EXECUTION START
# ------------------------------
check_dependencies
source "$CONFIG_FILE"

# Ensure scripts are executable
chmod +x "$SCRIPTS_DIR"/*.sh

# MAIN MENU
while true; do
    echo "=============================================="
    echo "   MongoDB Upgrade + Rollback Automation Tool"
    echo "=============================================="
    echo "1) Upgrade MongoDB"
    echo "2) Rollback MongoDB"
    echo "3) Validate MongoDB"
    echo "4) Precheck (Production Safety)"
    echo "5) Exit"
    echo ""
    read -rp "Choose an option (1-5): " ACTION

    case "$ACTION" in
        1)
            echo -e "\nUpgrade Options:\n1) 5.0\n2) 6.0\n3) 7.0\n4) 8.0\n"
            read -rp "Enter target version (1-4): " TARGET
            
            TGT_VER=""
            case "$TARGET" in
                1) TGT_VER="5.0" ;;
                2) TGT_VER="6.0" ;;
                3) TGT_VER="7.0" ;;
                4) TGT_VER="8.0" ;;
                *) echo "❌ Invalid option"; continue ;;
            esac

            # Initialize logging for upgrade
            CUR_VER=$(detect_current_version)
            init_logging "upgrade" "$CUR_VER" "$TGT_VER"
            set_log_context "EXPORT_FINAL_STATUS" "Failed" # default to Failed

            echo "=============================================="
            echo " Running Precheck Before Upgrade..."
            echo "=============================================="
            sudo bash -c "$PRECHECK_SCRIPT </dev/tty"

            case "$TARGET" in
                1) sudo "$SCRIPTS_DIR/mongodb_5_0.sh"
                   set_log_context "EXPORT_BACKUP_STATUS" "Success"
                   set +e
                   sudo bash -c "$VALIDATE_SCRIPT </dev/tty"
                   VAL_RC=$?
                   set -e
                   if [ $VAL_RC -eq 0 ]; then
                       set_log_context "EXPORT_VAL_STATUS" "Success"
                   else
                       set_log_context "EXPORT_VAL_STATUS" "Failed"
                       exit 1
                   fi
                   ;;
                2) sudo "$SCRIPTS_DIR/mongodb_6_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_6_to_5.sh" ;;
                3) sudo "$SCRIPTS_DIR/mongodb_7_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_7_to_6.sh" ;;
                4) sudo "$SCRIPTS_DIR/mongodb_8_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_8_to_7.sh" ;;
            esac

            set_log_context "EXPORT_FINAL_STATUS" "Success"
            write_execution_summary
            unset LOG_FILE EXEC_ID OP_START_EPOCH OP_START_TIME_STR OP_TYPE OP_SRC_VER OP_TARGET_VER EXPORT_BACKUP_STATUS EXPORT_VAL_STATUS EXPORT_ROLLBACK_TRIGGERED EXPORT_FINAL_STATUS
            ;;
        2)
            echo -e "\nRollback Options:\n1) 6 → 5\n2) 7 → 6\n3) 8 → 7\n"
            read -rp "Enter rollback choice (1/2/3): " RB
            
            SRC_VER=""
            TGT_VER=""
            case "$RB" in
                1) SRC_VER="6.0"; TGT_VER="5.0" ;;
                2) SRC_VER="7.0"; TGT_VER="6.0" ;;
                3) SRC_VER="8.0"; TGT_VER="7.0" ;;
                *) echo "❌ Invalid option"; continue ;;
            esac

            init_logging "rollback" "$SRC_VER" "$TGT_VER"
            set_log_context "EXPORT_FINAL_STATUS" "Failed"
            set_log_context "EXPORT_ROLLBACK_TRIGGERED" "Yes"

            sudo bash -c "$PRECHECK_SCRIPT </dev/tty"
            case "$RB" in
                1) sudo "$SCRIPTS_DIR/rollback_mongodb_6_to_5.sh" ;;
                2) sudo "$SCRIPTS_DIR/rollback_mongodb_7_to_6.sh" ;;
                3) sudo "$SCRIPTS_DIR/rollback_mongodb_8_to_7.sh" ;;
            esac

            echo "=============================================="
            echo " Running Validation After Rollback..."
            echo "=============================================="
            set +e
            sudo bash -c "$VALIDATE_SCRIPT </dev/tty"
            VAL_RC=$?
            set -e

            if [ $VAL_RC -eq 0 ]; then
                set_log_context "EXPORT_VAL_STATUS" "Success"
                set_log_context "EXPORT_FINAL_STATUS" "Success"
            else
                set_log_context "EXPORT_VAL_STATUS" "Failed"
                set_log_context "EXPORT_FINAL_STATUS" "Failed"
            fi

            write_execution_summary
            unset LOG_FILE EXEC_ID OP_START_EPOCH OP_START_TIME_STR OP_TYPE OP_SRC_VER OP_TARGET_VER EXPORT_BACKUP_STATUS EXPORT_VAL_STATUS EXPORT_ROLLBACK_TRIGGERED EXPORT_FINAL_STATUS
            ;;
        3)
            CUR_VER=$(detect_current_version)
            init_logging "validate" "$CUR_VER"
            set_log_context "EXPORT_FINAL_STATUS" "Failed"

            set +e
            sudo bash -c "$VALIDATE_SCRIPT </dev/tty"
            VAL_RC=$?
            set -e

            if [ $VAL_RC -eq 0 ]; then
                set_log_context "EXPORT_VAL_STATUS" "Success"
                set_log_context "EXPORT_FINAL_STATUS" "Success"
            else
                set_log_context "EXPORT_VAL_STATUS" "Failed"
                set_log_context "EXPORT_FINAL_STATUS" "Failed"
            fi

            write_execution_summary
            unset LOG_FILE EXEC_ID OP_START_EPOCH OP_START_TIME_STR OP_TYPE OP_SRC_VER OP_TARGET_VER EXPORT_BACKUP_STATUS EXPORT_VAL_STATUS EXPORT_ROLLBACK_TRIGGERED EXPORT_FINAL_STATUS
            ;;
        4)
            init_logging "precheck"
            set_log_context "EXPORT_FINAL_STATUS" "Failed"

            sudo bash -c "$PRECHECK_SCRIPT </dev/tty"

            set_log_context "EXPORT_FINAL_STATUS" "Success"
            write_execution_summary
            unset LOG_FILE EXEC_ID OP_START_EPOCH OP_START_TIME_STR OP_TYPE OP_SRC_VER OP_TARGET_VER EXPORT_BACKUP_STATUS EXPORT_VAL_STATUS EXPORT_ROLLBACK_TRIGGERED EXPORT_FINAL_STATUS
            ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "❌ Invalid option" ;;
    esac
done
