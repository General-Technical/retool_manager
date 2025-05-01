#!/bin/bash

# ===========================================================================
# Comprehensive Retool Environment Management Script
#
# This script provides complete management of multiple Retool environments
# including deployment, updates, backups, promotion between environments,
# health monitoring, and automated maintenance.
#
# Usage: manage_retool.sh [command] [environment] [options]
# ===========================================================================

# Set strict error handling
set -e

# Source the environment configuration
if [ -f "/opt/retool-config/environments.conf" ]; then
    source /opt/retool-config/environments.conf
else
    echo "ERROR: Configuration file not found at /opt/retool-config/environments.conf"
    exit 1
fi

# Default configuration values if not set in environments.conf
BACKUP_DIR=${BACKUP_DIR:-"/opt/retool-backups"}
MAX_BACKUPS=${MAX_BACKUPS:-10}
PROD_DIR=${PROD_DIR:-"/opt/retool-prod"}
STAGING_DIR=${STAGING_DIR:-"/opt/retool-staging"}
DEV_DIR=${DEV_DIR:-"/opt/retool-dev"}
PROD_VERSION_POLICY=${PROD_VERSION_POLICY:-"stable"}
STAGING_VERSION_POLICY=${STAGING_VERSION_POLICY:-"latest"}
DEV_VERSION_POLICY=${DEV_VERSION_POLICY:-"latest"}
LOG_DIR=${LOG_DIR:-"/var/log/retool"}
RETOOL_API_KEY_SECRET=${RETOOL_API_KEY_SECRET:-"retool_api_key"} # Name of Docker secret

# Default environment settings if not set in environments.conf
USE_PROD_ENV=${USE_PROD_ENV:-"true"}
USE_STAGING_ENV=${USE_STAGING_ENV:-"true"}
USE_DEV_ENV=${USE_DEV_ENV:-"true"}

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Define log files
MAIN_LOG="$LOG_DIR/retool-manager.log"
HEALTH_LOG="$LOG_DIR/retool-health.log"
BACKUP_LOG="$LOG_DIR/retool-backup.log"
ALERT_LOG="$LOG_DIR/retool-alerts.log"

# Command and environment arguments
COMMAND=$1
ENVIRONMENT=$2
OPTION=$3

# ===========================================================================
# Environment Configuration Functions
# ===========================================================================

# Function to get the list of enabled environments
get_enabled_environments() {
    local enabled_envs=()

    if [ "$USE_PROD_ENV" = "true" ]; then
        enabled_envs+=("prod")
    fi

    if [ "$USE_STAGING_ENV" = "true" ]; then
        enabled_envs+=("staging")
    fi

    if [ "$USE_DEV_ENV" = "true" ]; then
        enabled_envs+=("dev")
    fi

    echo "${enabled_envs[@]}"
}

# Function to check if an environment is enabled
is_environment_enabled() {
    local env=$1
    case "$env" in
        prod) [[ "$USE_PROD_ENV" == "true" ]];;
        staging) [[ "$USE_STAGING_ENV" == "true" ]];;
        dev) [[ "$USE_DEV_ENV" == "true" ]];;
        all) return 0;;
        *) return 1;; # Invalid environment
    esac
}

# ===========================================================================
# Utility Functions
# ===========================================================================

# Function to log messages with timestamps
log_message() {
    local level=$1
    local message=$2
    local log_file=$3

    # Default to main log if not specified
    log_file=${log_file:-$MAIN_LOG}

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"

    # If this is an alert, also log to alert log
    if [ "$level" = "ALERT" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$ALERT_LOG"
    fi
}

# Function to check if an environment directory exists
check_environment() {
    local env_dir=$1
    if [ ! -d "$env_dir" ]; then
        log_message "ERROR" "Environment directory $env_dir does not exist"
        exit 1
    fi
}

# Function to validate an environment
validate_environment() {
    local env=$1
    if ! is_environment_enabled "$env"; then
        log_message "ERROR" "Environment '$env' is disabled in configuration"
        exit 1
    fi
}

# Function to ensure Docker is running
ensure_docker_running() {
    if ! docker info &>/dev/null; then
        log_message "ERROR" "Docker daemon is not running"

        # Try to start Docker
        log_message "INFO" "Attempting to start Docker daemon..."
        if systemctl is-active --quiet docker; then
            log_message "INFO" "Docker service is actually running but not responding"
            log_message "INFO" "Attempting to restart Docker..."
            sudo systemctl restart docker
            if [ $? -ne 0 ]; then
                log_message "ERROR" "Failed to restart Docker service."
            fi
            sleep 5
        else
            log_message "INFO" "Starting Docker service..."
            sudo systemctl start docker
            if [ $? -ne 0 ]; then
                log_message "ERROR" "Failed to start Docker service."
            fi
            sleep 5
        fi

        # Check again
        if ! docker info &>/dev/null; then
            log_message "ERROR" "Failed to start Docker daemon. Manual intervention required."
            exit 1
        else
            log_message "INFO" "Docker daemon is now running"
        fi
    fi
}

# Function to fix permissions on directories
fix_permissions() {
    log_message "INFO" "Fixing permissions on Retool directories..."

    # Create directories if they don't exist
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$PROD_DIR"
    mkdir -p "$STAGING_DIR"
    mkdir -p "$DEV_DIR"
    mkdir -p "$LOG_DIR"

    # Set ownership
    current_user=$(whoami)
    sudo chown -R "$current_user:$current_user" "$BACKUP_DIR"
    sudo chown -R "$current_user:$current_user" "$PROD_DIR"
    sudo chown -R "$current_user:$current_user" "$STAGING_DIR"
    sudo chown -R "$current_user:$current_user" "$DEV_DIR"
    sudo chown -R "$current_user:$current_user" "$LOG_DIR"

    # Set permissions
    sudo chmod -R 755 "$BACKUP_DIR"
    sudo chmod -R 755 "$PROD_DIR"
    sudo chmod -R 755 "$STAGING_DIR"
    sudo chmod -R 755 "$DEV_DIR"
    sudo chmod -R 755 "$LOG_DIR"

    log_message "INFO" "Permissions fixed successfully"
}

# Function to clean up conflicting containers
clean_containers() {
    local env_name=$1
    local container_prefix=$2

    log_message "INFO" "Cleaning up conflicting containers for $env_name..."

    # Get list of containers with the specified prefix
    local containers=$(docker ps -a --format '{{.Names}}' | grep "^$container_prefix" || true)

    if [ -z "$containers" ]; then
        log_message "INFO" "No conflicting containers found for $env_name"
        return 0
    fi

    # Stop and remove containers
    for container in $containers; do
        if docker ps --format '{{.Names}}' | grep -q "^$container$"; then
            log_message "INFO" "Stopping container: $container"
            docker stop "$container"
            sleep 2
        fi

        log_message "INFO" "Removing container: $container"
        docker rm "$container"
    done

    log_message "INFO" "Container cleanup complete for $env_name"
}

# Function to check and handle potential container conflicts
handle_container_conflicts() {
    local env_name=$1
    local env_dir=$2

    log_message "INFO" "Checking for container conflicts before deploying $env_name..."

    # Define potential conflict patterns based on environment
    local conflict_patterns=()

    if [ "$env_name" = "development" ]; then
        conflict_patterns=("^temporal$" "^temporal-" "^retool-dev-")
    elif [ "$env_name" = "staging" ]; then
        conflict_patterns=("^retool-staging-")
    elif [ "$env_name" = "production" ]; then
        conflict_patterns=("^retool-prod-")
    fi

    # Check for each conflict pattern
    for pattern in "${conflict_patterns[@]}"; do
        # Get list of matching containers
        local containers=$(docker ps -a --format '{{.Names}}' | grep "$pattern" || true)

        if [ -n "$containers" ]; then
            log_message "INFO" "Found potentially conflicting containers matching $pattern"

            # Prompt for confirmation if in interactive mode
            if [ -t 0 ]; then
                read -p "Do you want to remove these containers? (y/n): " confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    log_message "ERROR" "Aborted due to container conflicts"
                    exit 1
                fi
            else
                # In non-interactive mode, always remove
                log_message "INFO" "Automatically removing conflicting containers in non-interactive mode"
            fi

            # Stop and remove containers
            for container in $containers; do
                if docker ps --format '{{.Names}}' | grep -q "^$container$"; then
                    log_message "INFO" "Stopping container: $container"
                    docker stop "$container"
                    sleep 2
                fi

                log_message "INFO" "Removing container: $container"
                docker rm "$container"
            done
        fi
    done

    log_message "INFO" "Container conflict check complete for $env_name"
}

# Function to rotate backups to save space
rotate_backups() {
    local env_name=$1

    log_message "INFO" "Rotating backups for $env_name environment..." "$BACKUP_LOG"

    # Count existing backups
    local backup_count=$(find "$BACKUP_DIR" -name "${env_name}_*" -type d | wc -l)

    # Remove oldest backups if we have too many
    if [ $backup_count -gt $MAX_BACKUPS ]; then
        local excess=$((backup_count - MAX_BACKUPS))
        log_message "INFO" "Removing $excess oldest backups for $env_name environment" "$BACKUP_LOG"

        find "$BACKUP_DIR" -name "${env_name}_*" -type d | sort | head -n "$excess" | xargs rm -rf
    fi

    log_message "INFO" "Backup rotation complete for $env_name" "$BACKUP_LOG"
}

# Function to read a secret from a Docker secret file
get_docker_secret() {
    local secret_name=$1
    local secret_file="/run/secrets/$secret_name"

    if [ -f "$secret_file" ]; then
        cat "$secret_file"
    else
        log_message "ERROR" "Docker secret '$secret_name' not found"
        exit 1
    fi
}

# ===========================================================================
# Core Management Functions
# ===========================================================================

# Function to get the appropriate version for an environment
get_version() {
    local env_name=$1
    local policy=$2
    local specific_version=$3

    log_message "INFO" "Determining version for $env_name environment with policy: $policy"

    # Call the get_version.sh script to determine the version
    if [ -x "/opt/retool-config/get_version.sh" ]; then
        local version=$("/opt/retool-config/get_version.sh" "$env_name" "$policy" "$specific_version")
        if [ $? -ne 0 ]; then
            log_message "ERROR" "get_version.sh script failed"
            exit 1
        fi
        log_message "INFO" "Selected version for $env_name: $version"
        echo "$version"
    else
        log_message "ERROR" "Version detection script not found or not executable"
        exit 1
    fi
}

# Function to backup an environment
backup_environment() {
    local env_name=$1
    local env_dir=$2
    local policy=$3
    local specific_version=$4

    log_message "INFO" "Starting backup for $env_name environment" "$BACKUP_LOG"

    # Check if environment exists
    check_environment "$env_dir"

    # Create a timestamped backup directory
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_path="$BACKUP_DIR/${env_name}_$timestamp"

    # Check if backup already exists
    if [ -d "$backup_path" ]; then
        log_message "WARNING" "Backup directory '$backup_path' already exists.  Skipping backup." "$BACKUP_LOG"
        echo "$backup_path"
        return
    fi

    mkdir -p "$backup_path"

    # Backup configuration files
    log_message "INFO" "Backing up configuration to $backup_path" "$BACKUP_LOG"
    cp "$env_dir/docker.env" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup docker.env" "$BACKUP_LOG"
    cp "$env_dir/retooldb.env" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup retooldb.env" "$BACKUP_LOG"
    cp "$env_dir/Dockerfile" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup Dockerfile" "$BACKUP_LOG"
    cp "$env_dir/docker-compose.yml" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup docker-compose.yml" "$BACKUP_LOG"

    # Backup database if it exists and is running
    if docker compose --project-directory "$env_dir" ps -q postgres &>/dev/null; then
        log_message "INFO" "Backing up database to $backup_path" "$BACKUP_LOG"
        docker compose --project-directory "$env_dir" exec -T postgres pg_dump -U retool retool > "$backup_path/database_backup.sql" 2>/dev/null || \
            log_message "WARNING" "Failed to backup database" "$BACKUP_LOG"
    else
        log_message "INFO" "Postgres container not running, skipping database backup" "$BACKUP_LOG"
    fi

    # Get current version from Dockerfile
    if [ -f "$env_dir/Dockerfile" ]; then
        local current_version=$(grep "ARG VERSION=" "$env_dir/Dockerfile" | cut -d= -f2)
        echo "$current_version" > "$backup_path/version.txt"
    fi

    # Rotate old backups
    rotate_backups "$env_name"

    log_message "INFO" "Backup complete for $env_name environment" "$BACKUP_LOG"

    # Return the backup path for other functions to use
    echo "$backup_path"
}

# Function to update a Retool environment
update_environment() {
    local env_name=$1
    local env_dir=$2
    local policy=$3
    local specific_version=$4
    local backup_only=$5

    log_message "INFO" "========================================================"
    log_message "INFO" "Starting update process for $env_name environment in $env_dir"
    log_message "INFO" "Using version policy: $policy"

    # Check if environment exists
    check_environment "$env_dir"

    # Ensure Docker is running
    ensure_docker_running

    # Create a backup
    local backup_path=$(backup_environment "$env_name" "$env_dir" "$policy" "$specific_version")

    # If backup only mode, exit here
    if [ "$backup_only" = "backup_only" ]; then
        log_message "INFO" "Backup-only mode, skipping update"
        log_message "INFO" "========================================================"
        return 0
    fi

    # Handle potential container conflicts
    handle_container_conflicts "$env_name" "$env_dir"

    # Get appropriate version
    local version=$(get_version "$env_name" "$policy" "$specific_version")
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to determine version for $env_name"
        exit 1
    fi

    # Update Dockerfile using envsubst
    log_message "INFO" "Updating Dockerfile to use version: $version"

    local dockerfile_template="$env_dir/Dockerfile.template"
    local dockerfile="$env_dir/Dockerfile"

    if [ ! -f "$dockerfile_template" ]; then
        log_message "ERROR" "Dockerfile.template not found in $env_dir"
        exit 1
    fi

    VERSION="$version"
    envsubst < "$dockerfile_template" > "$dockerfile"

    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to update Dockerfile using envsubst"
        exit 1
    fi

    # Rebuild and restart containers
    log_message "INFO" "Rebuilding containers with new version..."
    if ! docker compose --project-directory "$env_dir" build; then
        log_message "ERROR" "Failed to build containers. Check Docker logs for details."
        exit 1
    fi

    log_message "INFO" "Stopping current containers..."
    docker compose --project-directory "$env_dir" down

    log_message "INFO" "Starting new containers..."
    if ! docker compose --project-directory "$env_dir" up -d; then
        log_message "ERROR" "Failed to start containers. Check Docker logs for details."
        log_message "INFO" "Attempting to restore from backup..."

        # Restore Dockerfile from backup
        cp "$backup_path/Dockerfile" "$dockerfile"

        # Try to start with previous version
        docker compose --project-directory "$env_dir" build
        docker compose --project-directory "$env_dir" up -d

        log_message "INFO" "Restored to previous version after failed update"
    else
        # Clean up old images to save space
        log_message "INFO" "Cleaning up old images..."
        docker image prune -f
    fi

    log_message "INFO" "Update complete for $env_name environment"
    log_message "INFO" "========================================================"
}

# Function to show status of an environment
show_status() {
    local env_name=$1
    local env_dir=$2

    log_message "INFO" "========================================================"
    log_message "INFO" "Status for $env_name environment in $env_dir"

    # Check if environment exists
    if [ ! -d "$env_dir" ]; then
        log_message "WARNING" "Environment does not exist"
        log_message "INFO" "========================================================"
        return
    fi

    # Get current version from Dockerfile
    local current_version="Unknown"
    if [ -f "$env_dir/Dockerfile" ]; then
        current_version=$(grep "ARG VERSION=" "$env_dir/Dockerfile" | cut -d= -f2)
    fi
    log_message "INFO" "Current version: $current_version"

    # Show container status
    log_message "INFO" "Container status:"
    docker compose --project-directory "$env_dir" ps

    # Check database status if containers are running
    if docker compose --project-directory "$env_dir" ps -q postgres &>/dev/null; then
        log_message "INFO" "Database status:"
        if docker compose --project-directory "$env_dir" exec -T postgres pg_isready -U retool >/dev/null 2>&1; then
            log_message "INFO" "Database is responsive"

            # Check database size
            log_message "INFO" "Database size:"
            docker compose --project-directory "$env_dir" exec -T postgres psql -U retool -c "SELECT pg_size_pretty(pg_database_size('retool'));" || \
                log_message "WARNING" "Failed to query database size"
        else
            log_message "WARNING" "Database is not responsive"
        fi
    else
        log_message "WARNING" "Postgres container is not running"
    fi

    # Show disk usage
    log_message "INFO" "Disk usage for environment directory:"
    du -sh "$env_dir"

    # Show most recent backup
    local latest_backup=$(find "$BACKUP_DIR" -name "${env_name}_*" -type d | sort -r | head -1)
    if [ -n "$latest_backup" ]; then
        log_message "INFO" "Most recent backup: $(basename "$latest_backup")"
    else
        log_message "WARNING" "No backups found for this environment"
    fi

    log_message "INFO" "========================================================"
}

# Function to promote configuration from one environment to another
promote_environment() {
    local source_env=$1
    local target_env=$2
    local source_dir=$3
    local target_dir=$4

    log_message "INFO" "========================================================"
    log_message "INFO" "Promoting from $source_env to $target_env"

    # Check if environments exist
    check_environment "$source_dir"
    check_environment "$target_dir"

    # Create backup of target environment first
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_path="$BACKUP_DIR/${target_env}_pre_promotion_$timestamp"
    mkdir -p "$backup_path"

    log_message "INFO" "Backing up target environment to $backup_path"
    cp "$target_dir/docker.env" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup docker.env"
    cp "$target_dir/retooldb.env" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup retooldb.env"
    cp "$target_dir/Dockerfile" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup Dockerfile"
    cp "$target_dir/docker-compose.yml" "$backup_path/" 2>/dev/null || log_message "WARNING" "Failed to backup docker-compose.yml"

    # Get source version
    local source_version=""
    if [ -f "$source_dir/Dockerfile" ]; then
        source_version=$(grep "ARG VERSION=" "$source_dir/Dockerfile" | cut -d= -f2)
    else
        log_message "ERROR" "Source Dockerfile not found"
        exit 1
    fi

    # Update target Dockerfile using envsubst
    log_message "INFO" "Updating target to use version: $source_version"

    local dockerfile_template="$target_dir/Dockerfile.template"
    local dockerfile="$target_dir/Dockerfile"

    if [ ! -f "$dockerfile_template" ]; then
        log_message "ERROR" "Target Dockerfile template not found"
        exit 1
    fi

    VERSION="$source_version"
    envsubst < "$dockerfile_template" > "$dockerfile"

    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to update Dockerfile using envsubst"
        exit 1
    fi

    # Export apps from source environment (if running)
    log_message "INFO" "Checking if app export is possible..."
    if docker compose --project-directory "$source_dir" ps -q api &>/dev/null; then
        log_message "INFO" "Source environment is running, attempting to export apps..."

        # Get Retool API key from Docker secret
        local retool_api_key=$(get_docker_secret "$RETOOL_API_KEY_SECRET")

        # This is a placeholder for app export functionality
        # In a real implementation, you would use Retool's API to export apps
        log_message "INFO" "App export functionality would be implemented here"
        # Example: curl -H "Authorization: Bearer $retool_api_key" http://localhost:3000/api/export-apps > "$backup_path/apps.json"
    else
        log_message "WARNING" "Source environment is not running, cannot export apps"
    fi

    log_message "INFO" "Promotion complete. You should now update the environment to apply changes."
    log_message "INFO" "Run: manage_retool.sh update $target_env"
    log_message "INFO" "========================================================"
}

# Function to create a new environment
create_environment() {
    local env_name=$1
    local env_dir=$2
    local version_policy=$3
    local api_port=$4
    local http_port=$5
    local https_port=$6

    log_message "INFO" "========================================================"
    log_message "INFO" "Creating new $env_name environment in $env_dir"

    # Check if environment already exists
    if [ -d "$env_dir" ] && [ "$(ls -A "$env_dir" 2>/dev/null)" ]; then
        log_message "ERROR" "Environment directory $env_dir already exists and is not empty"
        exit 1
    fi

    # Ensure Docker is running
    ensure_docker_running

    # Create environment directory
    mkdir -p "$env_dir"

    # Clone Retool repository
    log_message "INFO" "Cloning Retool repository..."
    if ! git clone https://github.com/tryretool/retool-onpremise.git "$env_dir"; then
        log_message "ERROR" "Failed to clone Retool repository"
        exit 1
    fi

    # Get appropriate version
    log_message "INFO" "Determining version for $env_name environment..."
    local version=$(get_version "$env_name" "$version_policy")

    # Update Dockerfile using envsubst
    log_message "INFO" "Updating Dockerfile to use version: $version"
    local dockerfile_template="$env_dir/Dockerfile.template"
    local dockerfile="$env_dir/Dockerfile"

    if [ ! -f "$dockerfile_template" ]; then
        log_message "ERROR" "Dockerfile template not found in $env_dir"
        exit 1
    fi
    VERSION="$version"
    envsubst < "$dockerfile_template" > "$dockerfile"

    # Run Retool installation script
    log_message "INFO" "Running Retool installation script..."
    if ! "$env_dir/install.sh"; then
        log_message "ERROR" "Failed to run Retool installation script"
        exit 1
    fi

    # Update ports in docker-compose.yml if provided
    if [ -n "$api_port" ] && [ -n "$http_port" ] && [ -n "$https_port" ]; then
        log_message "INFO" "Updating ports in docker-compose.yml..."
        sed -i "s/\"3000:3000\"/\"$api_port:3000\"/" "$env_dir/docker-compose.yml"
        sed -i "s/\"80:80\"/\"$http_port:80\"/" "$env_dir/docker-compose.yml"
        sed -i "s/\"443:443\"/\"$https_port:443\"/" "$env_dir/docker-compose.yml"
    fi

    # Update environment configuration
    log_message "INFO" "Updating environment-specific configuration..."

    # Set environment-specific settings in docker.env
    if [ "$env_name" = "development" ]; then
        echo "NODE_ENV=development" >> "$env_dir/docker.env"
        echo "COOKIE_INSECURE=true" >> "$env_dir/docker.env"
    elif [ "$env_name" = "staging" ]; then
        echo "NODE_ENV=production" >> "$env_dir/docker.env"
        echo "COOKIE_INSECURE=false" >> "$env_dir/docker.env"
    elif [ "$env_name" = "production" ]; then
        echo "NODE_ENV=production" >> "$env_dir/docker.env"
        echo "COOKIE_INSECURE=false" >> "$env_dir/docker.env"
    fi

    log_message "INFO" "Environment $env_name created successfully"
    log_message "INFO" "You should now configure the environment and then update it to start containers"
    log_message "INFO" "========================================================"
}

# Function to start an environment
start_environment() {
    local env_name=$1
    local env_dir=$2

    log_message "INFO" "Starting $env_name environment in $env_dir"

    # Check if environment exists
    check_environment "$env_dir"

    # Ensure Docker is running
    ensure_docker_running

    # Start containers
    if docker compose --project-directory "$env_dir" up -d; then
        log_message "INFO" "$env_name environment started successfully"
    else
        log_message "ERROR" "Failed to start $env_name environment"
        exit 1
    fi

    # Check container status
    log_message "INFO" "Container status:"
    docker compose --project-directory "$env_dir" ps
}

# Function to stop an environment
stop_environment() {
    local env_name=$1
    local env_dir=$2

    log_message "INFO" "Stopping $env_name environment in $env_dir"

    # Check if environment exists
    check_environment "$env_dir"

    # Stop containers
    if docker compose --project-directory "$env_dir" down; then
        log_message "INFO" "$env_name environment stopped successfully"
    else
        log_message "ERROR" "Failed to stop $env_name environment"
        exit 1
    fi
}

# Function to check health of an environment
check_health() {
    local env_name=$1
    local env_dir=$2

    log_message "INFO" "Checking health of $env_name environment in $env_dir" "$HEALTH_LOG"

    # Check if environment exists
    if [ ! -d "$env_dir" ]; then
        log_message "WARNING" "Environment directory $env_dir does not exist" "$HEALTH_LOG"
        return
    fi

    # Check if containers are running
    local running_containers=$(docker compose --project-directory "$env_dir" ps --services --filter "status=running" | wc -l)
    log_message "INFO" "Running containers: $running_containers" "$HEALTH_LOG"

    # Expected number of services
    local expected_services=8  # Adjust based on your docker-compose.yml

    if [ $running_containers -lt $expected_services ]; then
        log_message "ALERT" "$env_name environment has only $running_containers/$expected_services containers running" "$HEALTH_LOG"

        # List non-running containers
        log_message "INFO" "Non-running containers:" "$HEALTH_LOG"
        docker compose --project-directory "$env_dir" ps --services --filter "status=exited" --filter "status=stopped" --filter "status=created"


        # Check for common issues
        log_message "INFO" "Checking logs for common issues..." "$HEALTH_LOG"
        docker compose --project-directory "$env_dir" logs --tail=50 | grep -E "ERROR|FATAL|Exception|failed"
    else
        log_message "INFO" "All expected containers are running" "$HEALTH_LOG"
    fi

    # Check database health
    if docker compose --project-directory "$env_dir" ps -q postgres &>/dev/null; then
        if docker compose --project-directory "$env_dir" exec -T postgres pg_isready -U retool >/dev/null 2>&1; then
            log_message "INFO" "Database is responsive" "$HEALTH_LOG"
        else
            log_message "ALERT" "Database is not responsive" "$HEALTH_LOG"
        fi
    else
        log_message "ALERT" "Postgres container is not running" "$HEALTH_LOG"
    fi

    # Check API health
    local api_container=$(docker compose --project-directory "$env_dir" ps -q api 2>/dev/null)
    if [ -n "$api_container" ]; then
        local api_port=$(docker port "$api_container" 3000 2>/dev/null | cut -d':' -f2)
        if [ -n "$api_port" ]; then
            local response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:"$api_port"/api/checkHealth 2>/dev/null)
            if [ "$response" = "200" ]; then
                log_message "INFO" "API is responding normally" "$HEALTH_LOG"
            else
                log_message "ALERT" "API health check failed. Response code: $response" "$HEALTH_LOG"
            fi
        else
            log_message "WARNING" "Could not determine API port" "$HEALTH_LOG"
        fi
    else
        log_message "ALERT" "API container is not running" "$HEALTH_LOG"
    fi

    # Check disk space
    local disk_usage=$(df -h "$env_dir" | tail -n 1)
    local usage_pct=$(echo "$disk_usage" | awk '{print $5}' | sed 's/%//')
    if [ "$usage_pct" -gt 90 ]; then
        log_message "ALERT" "Disk space critical: $usage_pct% used" "$HEALTH_LOG"
    elif [ "$usage_pct" -gt 80 ]; then
        log_message "WARNING" "Disk space warning: $usage_pct% used" "$HEALTH_LOG"
    else
        log_message "INFO" "Disk space OK: $usage_pct% used" "$HEALTH_LOG"
    fi

    log_message "INFO" "Health check complete for $env_name environment" "$HEALTH_LOG"
}

# Function to rollback to a previous backup
rollback_environment() {
    local env_name=$1
    local env_dir=$2
    local backup_id=$3

    log_message "INFO" "========================================================"
    log_message "INFO" "Rolling back $env_name environment to backup $backup_id"

    # Check if environment exists
    check_environment "$env_dir"

    # Validate backup_id to prevent command injection
    if ! [[ "$backup_id" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_message "ERROR" "Invalid backup ID. Only alphanumeric characters and underscores are allowed."
        exit 1
    fi

    # Find the backup
    local backup_path=$(find "$BACKUP_DIR" -name "${env_name}_${backup_id}*" -type d | head -1)

    if [ -z "$backup_path" ]; then
        log_message "ERROR" "Backup $backup_id not found for $env_name"
        exit 1
    fi

    log_message "INFO" "Using backup: $backup_path"

    # Create a backup of current state before rollback
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local pre_rollback_path="$BACKUP_DIR/${env_name}_pre_rollback_$timestamp"
    mkdir -p "$pre_rollback_path"

    # Backup current configuration
    cp "$env_dir/docker.env" "$pre_rollback_path/" 2>/dev/null || log_message "WARNING" "Failed to backup docker.env"
    cp "$env_dir/retooldb.env" "$pre_rollback_path/" 2>/dev/null || log_message "WARNING" "Failed to backup retooldb.env"
    cp "$env_dir/Dockerfile" "$pre_rollback_path/" 2>/dev/null || log_message "WARNING" "Failed to backup Dockerfile"
    cp "$env_dir/docker-compose.yml" "$pre_rollback_path/" 2>/dev/null || log_message "WARNING" "Failed to backup docker-compose.yml"

    # Restore configuration from backup
    log_message "INFO" "Restoring configuration files..."
    cp "$backup_path/docker.env" "$env_dir/" 2>/dev/null || log_message "WARNING" "Failed to restore docker.env"
    cp "$backup_path/retooldb.env" "$env_dir/" 2>/dev/null || log_message "WARNING" "Failed to restore retooldb.env"
    cp "$backup_path/Dockerfile" "$env_dir/" 2>/dev/null || log_message "WARNING" "Failed to restore Dockerfile"
    cp "$backup_path/docker-compose.yml" "$env_dir/" 2>/dev/null || log_message "WARNING" "Failed to restore docker-compose.yml"

    # Restore database if backup exists
    if [ -f "$backup_path/database_backup.sql" ]; then
        log_message "INFO" "Restoring database from backup"
        docker compose --project-directory "$env_dir" down
        docker compose --project-directory "$env_dir" up -d postgres

        # Wait for postgres to start
        log_message "INFO" "Waiting for database to start..."
        sleep 10

        # Check if postgres is ready
        attempt=1
        max_attempts=10

        while [ $attempt -le $max_attempts ]; do
            if docker compose --project-directory "$env_dir" exec -T postgres pg_isready -U retool >/dev/null 2>&1; then
                log_message "INFO" "Database is ready, proceeding with restore"
                break
            fi

            log_message "INFO" "Database not ready yet, waiting (attempt $attempt of $max_attempts)..."
            sleep 5
            attempt=$((attempt + 1))
        done

        if [ $attempt -gt $max_attempts ]; then
            log_message "ERROR" "Database failed to start in the expected time"
            log_message "INFO" "Rolling back will continue but database restore may fail"
        fi

        # Restore database
        log_message "INFO" "Loading database backup..."
        if ! cat "$backup_path/database_backup.sql" | docker compose --project-directory "$env_dir" exec -T postgres psql -U retool retool; then
            log_message "ERROR" "Failed to restore database from backup."
            exit 1 # Or handle the error more gracefully
        fi

        # Restart all services
        log_message "INFO" "Restarting all services with restored data..."
        docker compose --project-directory "$env_dir" down
        docker compose --project-directory "$env_dir" up -d
    else
        log_message "WARNING" "No database backup found, only configuration restored"
        # Restart with new configuration
        docker compose --project-directory "$env_dir" down
        docker compose --project-directory "$env_dir" up -d
    fi

    log_message "INFO" "Rollback complete for $env_name environment"
    log_message "INFO" "========================================================"
}

# Function to view logs for an environment
view_logs() {
    local env_name=$1
    local env_dir=$2
    local service=$3
    local lines=$4

    # Default to 100 lines if not specified
    lines=${lines:-100}

    log_message "INFO" "Viewing logs for $env_name environment"

    # Check if environment exists
    check_environment "$env_dir"

    # View logs
    if [ -n "$service" ]; then
        log_message "INFO" "Showing last $lines lines of logs for service: $service"
        docker compose --project-directory "$env_dir" logs --tail="$lines" "$service"
    else
        log_message "INFO" "Showing last $lines lines of logs for all services"
        docker compose --project-directory "$env_dir" logs --tail="$lines"
    fi
}

# Function to show a list of available backups
list_backups() {
    local env_name=$1

    log_message "INFO" "Listing available backups for $env_name environment"

    # Find backups for the specified environment
    local backups=$(find "$BACKUP_DIR" -name "${env_name}_*" -type d | sort -r)

    if [ -z "$backups" ]; then
        log_message "INFO" "No backups found for $env_name environment"
        return
    fi

    log_message "INFO" "Available backups for $env_name:"
    local count=1

    for backup in $backups; do
        local backup_name=$(basename "$backup")
        local backup_time=$(echo "$backup_name" | cut -d'_' -f2-3)
        local has_db=$([ -f "$backup/database_backup.sql" ] && echo "Yes" || echo "No")
        local version_file="$backup/version.txt"
        local version="Unknown"

        if [ -f "$version_file" ]; then
            version=$(cat "$version_file")
        fi

        log_message "INFO" "$count. $backup_name (Version: $version, Database: $has_db)"
        count=$((count + 1))
    done
}

# Function to optimize database
optimize_database() {
    local env_name=$1
    local env_dir=$2

    log_message "INFO" "Optimizing database for $env_name environment"

    # Check if environment exists
    check_environment "$env_dir"

    # Check if postgres container is running
    if ! docker compose --project-directory "$env_dir" ps -q postgres &>/dev/null; then
        log_message "ERROR" "Postgres container is not running for $env_name"
        exit 1
    fi

    # Vacuum analyze the database
    log_message "INFO" "Running VACUUM ANALYZE on database..."
    if docker compose --project-directory "$env_dir" exec -T postgres psql -U retool -c "VACUUM ANALYZE;" retool; then
        log_message "INFO" "Database optimization complete"
    else
        log_message "ERROR" "Failed to optimize database"
        exit 1
    fi
}

# Function to validate configuration
validate_config() {
    log_message "INFO" "Validating configuration..."

    # Check if directories exist
    if [ ! -d "$BACKUP_DIR" ]; then
        log_message "ERROR" "BACKUP_DIR '$BACKUP_DIR' does not exist"
        exit 1
    fi

    if [ ! -d "$LOG_DIR" ]; then
        log_message "ERROR" "LOG_DIR '$LOG_DIR' does not exist"
        exit 1
    fi

    # Check version policies (basic check, more robust validation might be needed)
    if [ -z "$PROD_VERSION_POLICY" ]; then
        log_message "WARNING" "PROD_VERSION_POLICY is not set"
    fi
    if [ -z "$STAGING_VERSION_POLICY" ]; then
        log_message "WARNING" "STAGING_VERSION_POLICY is not set"
    fi
    if [ -z "$DEV_VERSION_POLICY" ]; then
        log_message "WARNING" "DEV_VERSION_POLICY is not set"
    fi

    log_message "INFO" "Configuration validated successfully"
}

# Function to clean up a disabled environment
cleanup_env() {
    local env_name=$1
    local env_dir=$2

    log_message "INFO" "Cleaning up $env_name environment in $env_dir"

    # Check if environment is enabled
    if [ "$env_name" = "production" ] && [ "$USE_PROD_ENV" = "true" ]; then
        log_message "ERROR" "Cannot clean up production environment while it is enabled"
        exit 1
    elif [ "$env_name" = "staging" ] && [ "$USE_STAGING_ENV" = "true" ]; then
        log_message "ERROR" "Cannot clean up staging environment while it is enabled"
        exit 1
    elif [ "$env_name" = "development" ] && [ "$USE_DEV_ENV" = "true" ]; then
        log_message "ERROR" "Cannot clean up development environment while it is enabled"
        exit 1
    fi

    # Check if environment exists
    if [ ! -d "$env_dir" ]; then
        log_message "WARNING" "Environment directory $env_dir does not exist"
        return
    fi

    # Stop any running containers
    docker compose --project-directory "$env_dir" down 2>/dev/null || true

    # Remove directory
    rm -rf "$env_dir"

    log_message "INFO" "Environment $env_name cleaned up successfully"
}

# Function to manage environment configuration
manage_env_config() {
    local action=$1
    local target_env=$2

    if [ "$action" = "list" ]; then
        log_message "INFO" "Enabled environments:"
        if [ "$USE_PROD_ENV" = "true" ]; then
            log_message "INFO" "- Production (enabled)"
        else
            log_message "INFO" "- Production (disabled)"
        fi
        if [ "$USE_STAGING_ENV" = "true" ]; then
            log_message "INFO" "- Staging (enabled)"
        else
            log_message "INFO" "- Staging (disabled)"
        fi
        if [ "$USE_DEV_ENV" = "true" ]; then
            log_message "INFO" "- Development (enabled)"
        else
            log_message "INFO" "- Development (disabled)"
        fi
    elif [ "$action" = "enable" ]; then
        if [ -z "$target_env" ]; then
            log_message "ERROR" "Please specify an environment to enable"
            exit 1
        fi

        if [ "$target_env" = "prod" ]; then
            sed -i 's/USE_PROD_ENV=false/USE_PROD_ENV=true/' "/opt/retool-config/environments.conf"
            log_message "INFO" "Production environment enabled"
        elif [ "$target_env" = "staging" ]; then
            sed -i 's/USE_STAGING_ENV=false/USE_STAGING_ENV=true/' "/opt/retool-config/environments.conf"
            log_message "INFO" "Staging environment enabled"
        elif [ "$target_env" = "dev" ]; then
            sed -i 's/USE_DEV_ENV=false/USE_DEV_ENV=true/' "/opt/retool-config/environments.conf"
            log_message "INFO" "Development environment enabled"
        else
            log_message "ERROR" "Unknown environment '$target_env'. Use 'prod', 'staging', or 'dev'"
            exit 1
        fi
    elif [ "$action" = "disable" ]; then
        if [ -z "$target_env" ]; then
            log_message "ERROR" "Please specify an environment to disable"
            exit 1
        fi

        if [ "$target_env" = "prod" ]; then
            sed -i 's/USE_PROD_ENV=true/USE_PROD_ENV=false/' "/opt/retool-config/environments.conf"
            log_message "INFO" "Production environment disabled"
        elif [ "$target_env" = "staging" ]; then
            sed -i 's/USE_STAGING_ENV=true/USE_STAGING_ENV=false/' "/opt/retool-config/environments.conf"
            log_message "INFO" "Staging environment disabled"
        elif [ "$target_env" = "dev" ]; then
            sed -i 's/USE_DEV_ENV=true/USE_DEV_ENV=false/' "/opt/retool-config/environments.conf"
            log_message "INFO" "Development environment disabled"
        else
            log_message "ERROR" "Unknown environment '$target_env'. Use 'prod', 'staging', or 'dev'"
            exit 1
        fi
    else
        log_message "ERROR" "Unknown env-config action '$action'. Use 'list', 'enable', or 'disable'"
        exit 1
    fi
}

# ===========================================================================
# Main Logic
# ===========================================================================

# Validate configuration
validate_config

# Create necessary directories
mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

# Fix permissions if script is run by root
if [ "$(id -u)" = "0" ]; then
    fix_permissions
fi

# Ensure Docker is running
ensure_docker_running

# Main logic based on command
case $COMMAND in
    status)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; show_status "production" "$PROD_DIR";;
                    staging) validate_environment "staging"; show_status "staging" "$STAGING_DIR";;
                    dev) validate_environment "dev"; show_status "development" "$DEV_DIR";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; show_status "production" "$PROD_DIR";;
                staging) validate_environment "staging"; show_status "staging" "$STAGING_DIR";;
                dev) validate_environment "dev"; show_status "development" "$DEV_DIR";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    update)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; update_environment "production" "$PROD_DIR" "$PROD_VERSION_POLICY" "$PROD_SPECIFIC_VERSION";;
                    staging) validate_environment "staging"; update_environment "staging" "$STAGING_DIR" "$STAGING_VERSION_POLICY" "$STAGING_SPECIFIC_VERSION";;
                    dev) validate_environment "dev"; update_environment "development" "$DEV_DIR" "$DEV_VERSION_POLICY" "$DEV_SPECIFIC_VERSION";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; update_environment "production" "$PROD_DIR" "$PROD_VERSION_POLICY" "$PROD_SPECIFIC_VERSION";;
                staging) validate_environment "staging"; update_environment "staging" "$STAGING_DIR" "$STAGING_VERSION_POLICY" "$STAGING_SPECIFIC_VERSION";;
                dev) validate_environment "dev"; update_environment "development" "$DEV_DIR" "$DEV_VERSION_POLICY" "$DEV_SPECIFIC_VERSION";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    backup)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; update_environment "production" "$PROD_DIR" "$PROD_VERSION_POLICY" "$PROD_SPECIFIC_VERSION" "backup_only";;
                    staging) validate_environment "staging"; update_environment "staging" "$STAGING_DIR" "$STAGING_VERSION_POLICY" "$STAGING_SPECIFIC_VERSION" "backup_only";;
                    dev) validate_environment "dev"; update_environment "development" "$DEV_DIR" "$DEV_VERSION_POLICY" "$DEV_SPECIFIC_VERSION" "backup_only";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; update_environment "production" "$PROD_DIR" "$PROD_VERSION_POLICY" "$PROD_SPECIFIC_VERSION" "backup_only";;
                staging) validate_environment "staging"; update_environment "staging" "$STAGING_DIR" "$STAGING_VERSION_POLICY" "$STAGING_SPECIFIC_VERSION" "backup_only";;
                dev) validate_environment "dev"; update_environment "development" "$DEV_DIR" "$DEV_VERSION_POLICY" "$DEV_SPECIFIC_VERSION" "backup_only";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    promote)
        if [ "$ENVIRONMENT" = "dev-to-staging" ]; then
            validate_environment "dev"
            validate_environment "staging"
            promote_environment "development" "staging" "$DEV_DIR" "$STAGING_DIR"
        elif [ "$ENVIRONMENT" = "staging-to-prod" ]; then
            validate_environment "staging"
            validate_environment "prod"
            promote_environment "staging" "production" "$STAGING_DIR" "$PROD_DIR"
        elif [ "$ENVIRONMENT" = "dev-to-prod" ]; then
            validate_environment "dev"
            validate_environment "prod"
            promote_environment "development" "production" "$DEV_DIR" "$PROD_DIR"
        else
            log_message "ERROR" "Unknown promotion path '$ENVIRONMENT'. Use 'dev-to-staging', 'staging-to-prod', or 'dev-to-prod'"
            exit 1
        fi
        ;;

    create)
        if [ "$ENVIRONMENT" = "prod" ]; then
            validate_environment "prod"
            create_environment "production" "$PROD_DIR" "stable" "3030" "8030" "8445"
        elif [ "$ENVIRONMENT" = "staging" ]; then
            validate_environment "staging"
            create_environment "staging" "$STAGING_DIR" "latest" "3020" "8020" "8444"
        elif [ "$ENVIRONMENT" = "dev" ]; then
            validate_environment "dev"
            create_environment "development" "$DEV_DIR" "latest" "3010" "8010" "8443"
        else
            log_message "ERROR" "Unknown environment '$ENVIRONMENT'. Use 'prod', 'staging', or 'dev'"
            exit 1
        fi
        ;;

    start)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; start_environment "production" "$PROD_DIR";;
                    staging) validate_environment "staging"; start_environment "staging" "$STAGING_DIR";;
                    dev) validate_environment "dev"; start_environment "development" "$DEV_DIR";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; start_environment "production" "$PROD_DIR";;
                staging) validate_environment "staging"; start_environment "staging" "$STAGING_DIR";;
                dev) validate_environment "dev"; start_environment "development" "$DEV_DIR";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    stop)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; stop_environment "production" "$PROD_DIR";;
                    staging) validate_environment "staging"; stop_environment "staging" "$STAGING_DIR";;
                    dev) validate_environment "dev"; stop_environment "development" "$DEV_DIR";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; stop_environment "production" "$PROD_DIR";;
                staging) validate_environment "staging"; stop_environment "staging" "$STAGING_DIR";;
                dev) validate_environment "dev"; stop_environment "development" "$DEV_DIR";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    health)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; check_health "production" "$PROD_DIR";;
                    staging) validate_environment "staging"; check_health "staging" "$STAGING_DIR";;
                    dev) validate_environment "dev"; check_health "development" "$DEV_DIR";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; check_health "production" "$PROD_DIR";;
                staging) validate_environment "staging"; check_health "staging" "$STAGING_DIR";;
                dev) validate_environment "dev"; check_health "development" "$DEV_DIR";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    rollback)
        if [ -z "$OPTION" ]; then
            log_message "ERROR" "Rollback requires a backup ID"
            log_message "INFO" "Usage: manage_retool.sh rollback [environment] [backup_id]"
            exit 1
        fi

        BACKUP_ID=$OPTION

        if is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; rollback_environment "production" "$PROD_DIR" "$BACKUP_ID";;
                staging) validate_environment "staging"; rollback_environment "staging" "$STAGING_DIR" "$BACKUP_ID";;
                dev) validate_environment "dev"; rollback_environment "development" "$DEV_DIR" "$BACKUP_ID";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    logs)
        SERVICE=$OPTION
        LINES=$4

        if is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; view_logs "production" "$PROD_DIR" "$SERVICE" "$LINES";;
                staging) validate_environment "staging"; view_logs "staging" "$STAGING_DIR" "$SERVICE" "$LINES";;
                dev) validate_environment "dev"; view_logs "development" "$DEV_DIR" "$SERVICE" "$LINES";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    list-backups)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; list_backups "production";;
                    staging) validate_environment "staging"; list_backups "staging";;
                    dev) validate_environment "dev"; list_backups "development";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; list_backups "production";;
                staging) validate_environment "staging"; list_backups "staging";;
                dev) validate_environment "dev"; list_backups "development";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    optimize-db)
        if [ "$ENVIRONMENT" = "all" ]; then
            get_enabled_environments | while read -r env; do
                case "$env" in
                    prod) validate_environment "prod"; optimize_database "production" "$PROD_DIR";;
                    staging) validate_environment "staging"; optimize_database "staging" "$STAGING_DIR";;
                    dev) validate_environment "dev"; optimize_database "development" "$DEV_DIR";;
                esac
            done
        elif is_environment_enabled "$ENVIRONMENT"; then
            case "$ENVIRONMENT" in
                prod) validate_environment "prod"; optimize_database "production" "$PROD_DIR";;
                staging) validate_environment "staging"; optimize_database "staging" "$STAGING_DIR";;
                dev) validate_environment "dev"; optimize_database "development" "$DEV_DIR";;
                *) log_message "ERROR" "Unknown environment '$ENVIRONMENT'"; exit 1;;
            esac
        else
            log_message "ERROR" "Environment '$ENVIRONMENT' is disabled or invalid"
            exit 1
        fi
        ;;

    cleanup)
        log_message "INFO" "Cleaning up Docker resources..."
        docker system prune -f
        log_message "INFO" "Cleanup complete"
        ;;

    env-config)
        manage_env_config "$OPTION" "$ENVIRONMENT"
        ;;

    cleanup-env)
        if [ "$ENVIRONMENT" = "prod" ]; then
            cleanup_env "production" "$PROD_DIR"
        elif [ "$ENVIRONMENT" = "staging" ]; then
            cleanup_env "staging" "$STAGING_DIR"
        elif [ "$ENVIRONMENT" = "dev" ]; then
            cleanup_env "development" "$DEV_DIR"
        else
            log_message "ERROR" "Unknown environment '$ENVIRONMENT'. Use 'prod', 'staging', or 'dev'"
            exit 1
        fi
        ;;

    fix-permissions)
        fix_permissions
        ;;

    *)
        echo "Retool Environment Management Tool"
        echo "Usage: manage_retool.sh [command] [environment] [options]"
        echo ""
        echo "Commands:"
        echo "  status         - Show status of environment(s)"
        echo "  update         - Update environment(s) to appropriate version"
        echo "  backup         - Create backup of environment(s) without updating"
        echo "  promote        - Promote configuration from one environment to another"
        echo "  create         - Create a new environment"
        echo "  start          - Start environment(s)"
        echo "  stop           - Stop environment(s)"
        echo "  health         - Check health of environment(s)"
        echo "  rollback       - Roll back to a previous backup"
        echo "  logs           - View logs for an environment"
        echo "  list-backups   - List available backups"
        echo "  optimize-db    - Optimize database"
        echo "  cleanup        - Clean up Docker resources"
        echo "  env-config     - Manage environment configuration"
        echo "    list         - List enabled environments"
        echo "    enable       - Enable an environment"
        echo "    disable      - Disable an environment"
        echo "  cleanup-env    - Remove a disabled environment completely"
        echo "  fix-permissions - Fix permissions on Retool directories"
        echo ""
        echo "Environments:"
        echo "  prod    - Production environment"
        echo "  staging - Staging environment"
        echo "  dev     - Development environment"
        echo "  all     - All environments (for status, update, backup, etc.)"
        echo ""
        echo "For promote command, use these environment specifiers:"
        echo "  dev-to-staging  - Promote from development to staging"
        echo "  staging-to-prod - Promote from staging to production"
        echo "  dev-to-prod     - Promote from development directly to production"
        echo ""
        echo "Examples:"
        echo "  manage_retool.sh status all            - Show status of all environments"
        echo "  manage_retool.sh update dev            - Update development environment"
        echo "  manage_retool.sh promote dev-to-staging - Promote from dev to staging"
        echo "  manage_retool.sh create prod           - Create production environment"
        echo "  manage_retool.sh rollback dev 20250424 - Roll back dev to backup from April 24, 2025"
        echo "  manage_retool.sh logs dev api 100      - View last 100 lines of API logs for dev"
        exit 1
        ;;
esac

exit 0
