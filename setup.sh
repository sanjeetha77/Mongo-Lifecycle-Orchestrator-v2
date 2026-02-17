#!/usr/bin/env bash
# Production Setup: Preparation of the local environment

echo "🔧 Initializing Production Environment..."

# 1. Create necessary system folders
sudo mkdir -p /var/log/mongodb-upgrade /var/lib/mongodb-upgrade /var/backups/mongodb

# 2. Set permissions
sudo chown -R $USER:$USER /var/log/mongodb-upgrade /var/lib/mongodb-upgrade

# 3. Generate Security Keyfile if not exists
if [ ! -f "./mongo-keyfile" ]; then
    openssl rand -base64 756 > mongo-keyfile
    chmod 400 mongo-keyfile
    echo "✅ Security Keyfile generated."
fi

# 4. Ensure scripts are executable
chmod +x main.sh scripts/*.sh

echo "🚀 Setup Complete. You can now run ./main.sh"
