#!/bin/bash

# Specialized script for deploying the development environment
echo "Starting Retool Development Environment Deployment"

# Source environment configuration
source /opt/retool-config/environments.conf

# Fix permissions first
/opt/retool-config/fix-permissions.sh

# Clean up any conflicting containers
/opt/retool-config/container-cleanup.sh

# Function to check if directory is empty
is_directory_empty() {
    if [ -z "$(ls -A $1 2>/dev/null)" ]; then
        return 0
    else
        return 1
    fi
}

# Set up dev directory if needed
if is_directory_empty $DEV_DIR; then
    echo "Development directory is empty. Setting up from scratch..."
    
    # Clone Retool repository
    git clone https://github.com/tryretool/retool-onpremise.git $DEV_DIR
    
    # Initialize with install script
    cd $DEV_DIR
    ./install.sh
    
    # If using an existing installation as a template, copy configuration
    if [ -d "~/retool" ] && [ ! -z "$(ls -A ~/retool)" ]; then
        echo "Copying configuration from existing installation..."
        cp ~/retool/docker.env $DEV_DIR/
        cp ~/retool/retooldb.env $DEV_DIR/
    fi
else
    echo "Development directory already exists. Using existing setup."
fi

# Update environment-specific settings
cd $DEV_DIR

# Modify docker.env for development environment
if grep -q "COOKIE_INSECURE" docker.env; then
    sed -i 's/COOKIE_INSECURE=.*/COOKIE_INSECURE=true/' docker.env
else
    echo "COOKIE_INSECURE=true" >> docker.env
fi

# Update docker-compose.yml to use unique ports if needed
if grep -q "3000:3000" docker-compose.yml; then
    echo "Updating ports in docker-compose.yml..."
    sed -i 's/"3000:3000"/"3000:3000"/' docker-compose.yml  # Keep same for dev
    sed -i 's/"80:80"/"8080:80"/' docker-compose.yml
    sed -i 's/"443:443"/"8443:443"/' docker-compose.yml
fi

# Get latest development version
echo "Fetching latest version for development environment..."
DEV_VERSION=$(/opt/retool-config/get_version.sh dev latest)

# Backup the current configuration
echo "Backing up configuration..."
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="$BACKUP_DIR/development_$TIMESTAMP"
mkdir -p $BACKUP_DIR
cp docker.env $BACKUP_DIR/
cp retooldb.env $BACKUP_DIR/
cp Dockerfile $BACKUP_DIR/
cp docker-compose.yml $BACKUP_DIR/

# Update the Dockerfile with the correct version
echo "Updating Dockerfile to use version: $DEV_VERSION"
sed -i "s/ARG VERSION=.*/ARG VERSION=$DEV_VERSION/" Dockerfile

# Build and start containers
echo "Building containers..."
docker compose build

echo "Starting containers..."
docker compose up -d

# Wait for containers to start
echo "Waiting for containers to start..."
sleep 20

# Check if everything is running
echo "Checking container status..."
docker compose ps

echo "Development environment deployment complete!"
echo "Access Retool at: http://localhost:3000"

# Run a health check
echo "Running health check..."
/opt/retool-config/health-monitor.sh dev
