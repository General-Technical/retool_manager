#!/bin/bash

# =============================================================================
# Retool Development Environment Deployment Script (v2)
# Based on Retool self-hosted documentation and best practices
# =============================================================================

# Specialized script for deploying the development environment
echo "Starting Retool Development Environment Deployment (v2)"

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

# CRITICAL FIX: Make sure retooldb.env exists and has correct content
echo "Ensuring retooldb.env file exists with proper configuration..."
cat > retooldb.env << EOL
# Configuration for the retooldb-postgres container
POSTGRES_DB=retooldb
POSTGRES_USER=retool
POSTGRES_PASSWORD=retool
EOL
echo "retooldb.env created/updated successfully"

# Force proper permissions for retooldb.env
chmod 644 retooldb.env

# Update docker.env with complete configuration
echo "Ensuring docker.env has proper configuration..."
if [ ! -f "docker.env" ]; then
    # Create from scratch if missing
    cat > docker.env << EOL
# Database configuration for Retool's main storage database
POSTGRES_DB=retool
POSTGRES_USER=retool
POSTGRES_PASSWORD=retool
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_POOL_MAX_SIZE=20

# General Retool configuration
NODE_ENV=development
COOKIE_INSECURE=true
JWT_SECRET=$(openssl rand -hex 16)
ENCRYPTION_KEY=$(openssl rand -hex 16)
LICENSE_KEY=

# Performance tuning
DBCONNECTOR_QUERY_TIMEOUT_MS=300000
EOL
else
    # Update existing file
    if ! grep -q "POSTGRES_DB" docker.env; then
        echo "POSTGRES_DB=retool" >> docker.env
    fi
    if ! grep -q "POSTGRES_USER" docker.env; then
        echo "POSTGRES_USER=retool" >> docker.env
    fi
    if ! grep -q "POSTGRES_PASSWORD" docker.env; then
        echo "POSTGRES_PASSWORD=retool" >> docker.env
    fi
    if ! grep -q "COOKIE_INSECURE" docker.env; then
        echo "COOKIE_INSECURE=true" >> docker.env
    else
        sed -i 's/COOKIE_INSECURE=.*/COOKIE_INSECURE=true/' docker.env
    fi
    if ! grep -q "JWT_SECRET" docker.env; then
        echo "JWT_SECRET=$(openssl rand -hex 16)" >> docker.env
    fi
    if ! grep -q "ENCRYPTION_KEY" docker.env; then
        echo "ENCRYPTION_KEY=$(openssl rand -hex 16)" >> docker.env
    fi
fi

# Force proper permissions for docker.env
chmod 644 docker.env

# Update docker-compose.yml to use unique ports
echo "Updating ports in docker-compose.yml..."
sed -i 's/"3000:3000"/"3000:3000"/' docker-compose.yml  # Keep same for dev
sed -i 's/"80:80"/"8080:80"/' docker-compose.yml
sed -i 's/"443:443"/"8443:443"/' docker-compose.yml

# Get latest development version
echo "Fetching latest version for development environment..."
DEV_VERSION=$(/opt/retool-config/get_version.sh dev latest)
echo "Selected version for dev environment: $DEV_VERSION"

# Backup the current configuration
echo "Backing up configuration..."
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_DIR:-/opt/retool-backups}/development_$TIMESTAMP"
mkdir -p $BACKUP_DIR
cp docker.env $BACKUP_DIR/ 2>/dev/null || echo "Warning: Failed to backup docker.env"
cp retooldb.env $BACKUP_DIR/ 2>/dev/null || echo "Warning: Failed to backup retooldb.env"
cp Dockerfile $BACKUP_DIR/ 2>/dev/null || echo "Warning: Failed to backup Dockerfile"
cp docker-compose.yml $BACKUP_DIR/ 2>/dev/null || echo "Warning: Failed to backup docker-compose.yml"

# Update the Dockerfile with the correct version
echo "Updating Dockerfile to use version: $DEV_VERSION"
sed -i "s/ARG VERSION=.*/ARG VERSION=$DEV_VERSION/" Dockerfile

# Verify files exist before starting
echo "Verifying configuration files..."
if [ ! -f "retooldb.env" ]; then
    echo "ERROR: retooldb.env still missing after creation attempt. Stopping deployment."
    exit 1
fi
if [ ! -f "docker.env" ]; then
    echo "ERROR: docker.env still missing after creation attempt. Stopping deployment."
    exit 1
fi

# Stop any running containers to ensure clean start
echo "Stopping any existing containers..."
docker compose down

# Build and start containers
echo "Building containers..."
docker compose build

echo "Starting containers..."
docker compose up -d

# Wait for containers to start
echo "Waiting for containers to start..."
sleep 45  # Extended wait time

# Check if everything is running
echo "Checking container status..."
docker compose ps

# Check for specific containers
if [ -z "$(docker compose ps -q postgres)" ]; then
    echo "❌ ERROR: Postgres container is not running!"
    echo "Checking docker-compose logs for postgres..."
    docker compose logs postgres
else
    echo "✅ Postgres container is running"
fi

if [ -z "$(docker compose ps -q retooldb-postgres)" ]; then
    echo "❌ ERROR: RetoolDB Postgres container is not running!"
    echo "Checking docker-compose logs for retooldb-postgres..."
    docker compose logs retooldb-postgres
else
    echo "✅ RetoolDB Postgres container is running"
fi

# Verify database connectivity
echo "Verifying database connectivity..."
if docker compose exec -T postgres pg_isready -U retool > /dev/null 2>&1; then
    echo "✅ Main database is ready"
else
    echo "❌ Warning: Main database is not responding. Check container logs for details."
fi

if docker compose exec -T retooldb-postgres pg_isready -U retool > /dev/null 2>&1; then
    echo "✅ RetoolDB database is ready"
else
    echo "❌ Warning: RetoolDB database is not responding. Check container logs for details."
fi

# Check Retool API health
echo "Checking Retool API health..."
API_HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/checkHealth 2>/dev/null)
if [ "$API_HEALTH_STATUS" = "200" ]; then
    echo "✅ Retool API is healthy"
else
    echo "❌ Warning: Retool API is not responding correctly. Status code: $API_HEALTH_STATUS"
    echo "Checking docker-compose logs for api..."
    docker compose logs api
fi

echo "==================================================="
echo "Development environment deployment complete!"
echo "Access Retool at: http://localhost:3000"
echo ""
echo "Default database credentials:"
echo "  Database: retool"
echo "  Username: retool"
echo "  Password: retool"
echo ""
echo "You'll need to create an admin account on first login"
echo "==================================================="

# Run a health check
echo "Running health check..."
/opt/retool-config/health-monitor.sh dev
