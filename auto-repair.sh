#!/bin/bash

# Automatic repair script for Retool environments
echo "Starting automatic repair process..."

# Source environment configuration
source /opt/retool-config/environments.conf

# Define log file
LOG_FILE="/var/log/retool-repair.log"

# Function to log messages with timestamps
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Function to repair an environment
repair_environment() {
    local env_name=$1
    local env_dir=$2
    
    log_message "Starting repair for $env_name environment..."
    
    if [ ! -d "$env_dir" ]; then
        log_message "Environment directory $env_dir does not exist"
        return 1
    fi
    
    cd $env_dir
    
    # Check if Docker Compose is working
    if ! docker compose ps &>/dev/null; then
        log_message "Docker Compose not working in $env_dir. Checking for issues..."
        
        # Check if docker-compose.yml exists
        if [ ! -f "docker-compose.yml" ]; then
            log_message "docker-compose.yml is missing. Trying to restore from backup..."
            
            # Find most recent backup
            latest_backup=$(find $BACKUP_DIR -name "${env_name}_*" -type d | sort -r | head -1)
            
            if [ -n "$latest_backup" ] && [ -f "$latest_backup/docker-compose.yml" ]; then
                log_message "Restoring docker-compose.yml from $latest_backup"
                cp "$latest_backup/docker-compose.yml" ./
            else
                log_message "No backup found. Cannot repair automatically."
                return 1
            fi
        fi
    fi
    
    # Check container health
    unhealthy_containers=$(docker compose ps --format "{{.Name}}" --filter "health=unhealthy")
    if [ -n "$unhealthy_containers" ]; then
        log_message "Found unhealthy containers: $unhealthy_containers"
        log_message "Restarting unhealthy containers..."
        
        for container in $unhealthy_containers; do
            log_message "Restarting $container..."
            docker compose restart $container
        done
    fi
    
    # Check if database is responsive
    if docker compose ps postgres | grep -q "Up"; then
        if ! docker compose exec -T postgres pg_isready -U retool &>/dev/null; then
            log_message "Database is not responsive. Restarting postgres container..."
            docker compose restart postgres
            sleep 10
        fi
    else
        log_message "Postgres container is not running. Starting it..."
        docker compose up -d postgres
        sleep 10
    fi
    
    # Check for missing containers
    expected_services=(postgres retooldb-postgres api jobs-runner workflows-worker workflows-backend code-executor https-portal)
    for service in "${expected_services[@]}"; do
        if ! docker compose ps $service | grep -q "Up"; then
            log_message "$service is not running. Starting it..."
            docker compose up -d $service
        fi
    done
    
    # Final check - restart everything if still having issues
    if ! docker compose ps | grep -q "Up" || [ $(docker compose ps --services --filter "status=running" | wc -l) -lt 6 ]; then
        log_message "Still having issues. Performing complete restart..."
        docker compose down
        sleep 5
        docker compose up -d
    fi
    
    log_message "Repair process completed for $env_name"
}

# Main function
main() {
    log_message "Starting Retool automatic repair"
    
    # Ensure log file exists and is writable
    touch $LOG_FILE
    chmod 644 $LOG_FILE
    
    # Fix permissions first
    /opt/retool-config/fix-permissions.sh
    
    # Repair environments based on parameter
    if [ "$1" = "all" ] || [ "$1" = "dev" ]; then
        repair_environment "development" $DEV_DIR
    fi
    
    if [ "$1" = "all" ] || [ "$1" = "staging" ]; then
        repair_environment "staging" $STAGING_DIR
    fi
    
    if [ "$1" = "all" ] || [ "$1" = "prod" ]; then
        repair_environment "production" $PROD_DIR
    fi
    
    log_message "Automatic repair process complete"
}

# Run the main function with the provided argument
main ${1:-"all"}
