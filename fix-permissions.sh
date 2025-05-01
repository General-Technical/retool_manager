#!/bin/bash

# Fix permissions for Retool configuration directories
echo "Fixing permissions for Retool configuration directories..."

# Create directories if they don't exist
sudo mkdir -p /opt/retool-config
sudo mkdir -p /opt/retool-backups
sudo mkdir -p /opt/retool-prod
sudo mkdir -p /opt/retool-staging
sudo mkdir -p /opt/retool-dev

# Set appropriate ownership (assuming your user is running the containers)
sudo chown -R $(whoami):$(whoami) /opt/retool-config
sudo chown -R $(whoami):$(whoami) /opt/retool-backups
sudo chown -R $(whoami):$(whoami) /opt/retool-prod
sudo chown -R $(whoami):$(whoami) /opt/retool-staging
sudo chown -R $(whoami):$(whoami) /opt/retool-dev

# Set appropriate permissions
sudo chmod -R 755 /opt/retool-config
sudo chmod -R 755 /opt/retool-backups
sudo chmod -R 755 /opt/retool-prod
sudo chmod -R 755 /opt/retool-staging
sudo chmod -R 755 /opt/retool-dev

echo "Permissions fixed successfully!"
