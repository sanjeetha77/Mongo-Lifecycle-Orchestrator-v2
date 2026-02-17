#!/usr/bin/env bash

clean_repos() {
    local target=$1
    echo "[SYSTEM] Isolating Repository for version $target..."
    # Remove all mongo lists to avoid collisions
    sudo rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    sudo apt-get clean
    sudo apt-get update -y > /dev/null
}
