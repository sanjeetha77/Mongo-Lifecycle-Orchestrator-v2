#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
VALIDATE_SCRIPT="$SCRIPTS_DIR/validate_mongodb.sh"
PRECHECK_SCRIPT="$SCRIPTS_DIR/precheck_mongodb.sh"
CONFIG_FILE="$BASE_DIR/config.env"

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
        return 0
    fi

    echo -e "\n❌ VALIDATION FAILED!"
    echo "⚠️ Auto rollback will start now..."
    sudo "$rollback_script"
    
    echo "=============================================="
    echo " Running Validation After Rollback..."
    echo "=============================================="
    sudo bash -c "$VALIDATE_SCRIPT </dev/tty" || true
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
            
            echo "=============================================="
            echo " Running Precheck Before Upgrade..."
            echo "=============================================="
            sudo bash -c "$PRECHECK_SCRIPT </dev/tty"

            case "$TARGET" in
                1) sudo "$SCRIPTS_DIR/mongodb_5_0.sh"
                   sudo bash -c "$VALIDATE_SCRIPT </dev/tty" ;;
                2) sudo "$SCRIPTS_DIR/mongodb_6_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_6_to_5.sh" ;;
                3) sudo "$SCRIPTS_DIR/mongodb_7_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_7_to_6.sh" ;;
                4) sudo "$SCRIPTS_DIR/mongodb_8_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_8_to_7.sh" ;;
                *) echo "❌ Invalid option" ;;
            esac
            ;;
        2)
            echo -e "\nRollback Options:\n1) 6 → 5\n2) 7 → 6\n3) 8 → 7\n"
            read -rp "Enter rollback choice (1/2/3): " RB
            sudo bash -c "$PRECHECK_SCRIPT </dev/tty"
            case "$RB" in
                1) sudo "$SCRIPTS_DIR/rollback_mongodb_6_to_5.sh" ;;
                2) sudo "$SCRIPTS_DIR/rollback_mongodb_7_to_6.sh" ;;
                3) sudo "$SCRIPTS_DIR/rollback_mongodb_8_to_7.sh" ;;
                *) echo "❌ Invalid option" ;;
            esac
            sudo bash -c "$VALIDATE_SCRIPT </dev/tty" || true
            ;;
        3) sudo bash -c "$VALIDATE_SCRIPT </dev/tty" ;;
        4) sudo bash -c "$PRECHECK_SCRIPT </dev/tty" ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "❌ Invalid option" ;;
    esac
done#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
VALIDATE_SCRIPT="$SCRIPTS_DIR/validate_mongodb.sh"
PRECHECK_SCRIPT="$SCRIPTS_DIR/precheck_mongodb.sh"
CONFIG_FILE="$BASE_DIR/config.env"

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
        return 0
    fi

    echo -e "\n❌ VALIDATION FAILED!"
    echo "⚠️ Auto rollback will start now..."
    sudo "$rollback_script"
    
    echo "=============================================="
    echo " Running Validation After Rollback..."
    echo "=============================================="
    sudo bash -c "$VALIDATE_SCRIPT </dev/tty" || true
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
            
            echo "=============================================="
            echo " Running Precheck Before Upgrade..."
            echo "=============================================="
            sudo bash -c "$PRECHECK_SCRIPT </dev/tty"

            case "$TARGET" in
                1) sudo "$SCRIPTS_DIR/mongodb_5_0.sh"
                   sudo bash -c "$VALIDATE_SCRIPT </dev/tty" ;;
                2) sudo "$SCRIPTS_DIR/mongodb_6_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_6_to_5.sh" ;;
                3) sudo "$SCRIPTS_DIR/mongodb_7_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_7_to_6.sh" ;;
                4) sudo "$SCRIPTS_DIR/mongodb_8_0.sh"
                   run_validation_or_rollback "$SCRIPTS_DIR/rollback_mongodb_8_to_7.sh" ;;
                *) echo "❌ Invalid option" ;;
            esac
            ;;
        2)
            echo -e "\nRollback Options:\n1) 6 → 5\n2) 7 → 6\n3) 8 → 7\n"
            read -rp "Enter rollback choice (1/2/3): " RB
            sudo bash -c "$PRECHECK_SCRIPT </dev/tty"
            case "$RB" in
                1) sudo "$SCRIPTS_DIR/rollback_mongodb_6_to_5.sh" ;;
                2) sudo "$SCRIPTS_DIR/rollback_mongodb_7_to_6.sh" ;;
                3) sudo "$SCRIPTS_DIR/rollback_mongodb_8_to_7.sh" ;;
                *) echo "❌ Invalid option" ;;
            esac
            sudo bash -c "$VALIDATE_SCRIPT </dev/tty" || true
            ;;
        3) sudo bash -c "$VALIDATE_SCRIPT </dev/tty" ;;
        4) sudo bash -c "$PRECHECK_SCRIPT </dev/tty" ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "❌ Invalid option" ;;
    esac
done
