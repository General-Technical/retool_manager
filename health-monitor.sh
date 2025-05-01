#!/bin/bash

# Source environment configuration
source /opt/retool-config/environments.conf

# Define log file
LOG_FILE="/var/log/retool-health.log"
ALERT_FILE="/var/log/retool-alerts.log"

# Function to log messages with timestamps
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Function to log alerts with timestamps
log_alert() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERT: $1" | tee -a $LOG_FILE $ALERT_FILE
}

# Check if a file exists and is not older than specified minutes
check_file_fresh() {
    local file=$1
    local max_age_minutes=$2
    
    if [ ! -f "$file" ]; then
        return 1
    fi
    
    # Get file modification time in seconds since epoch
    local file_time=$(stat -c %Y "$file")
    local current_time=$(date +%s)
    local age_seconds=$((current_time - file_time))
    local age_minutes=$((age_seconds / 60))
    
    if [ $age_minutes -gt $max_age_minutes ]; then
        return 1
    fi
    
    return 0
}

# Function to check disk space
check_disk_space() {
    log_message "Checking disk space..."
    
    # Check disk space on the filesystem containing /opt/retool-*
    DISK_USAGE=$(df -h /opt | tail -n 1)
    USAGE_PCT=$(echo $DISK_USAGE | awk '{print $5}' | sed 's/%//')
    
    if [ $USAGE_PCT -gt 90 ]; then
        log_alert "Disk space critical: $USAGE_PCT% used on $(echo $DISK_USAGE | awk '{print $1}')"
        return 1
    elif [ $USAGE_PCT -gt 80 ]; then
        log_message "Disk space warning: $USAGE_PCT% used on $(echo $DISK_USAGE | awk '{print $1}')"
        return 0
    else
        log_message "Disk space OK: $USAGE_PCT% used"
        return 0
    fi
}

# Function to check Docker daemon health
check_docker_health() {
    log_message "Checking Docker daemon health..."
    
    if ! docker info &>/dev/null; then
        log_alert "Docker daemon is not responding!"
        return 1
    else
        log_message "Docker daemon is healthy"
        return 0
    fi
}

# Function to check container CPU and memory usage
check_container_resources() {
    local env_dir=$1
    local env_name=$2
    
    log_message "Checking container resource usage for $env_name..."
    
    if [ ! -d "$env_dir" ]; then
        log_message "$env_name environment directory does not exist"
        return 0
    fi
    
    cd $env_dir
    
    # Get list of running containers
    local containers=$(docker compose ps -q)
    
    if [ -z "$containers" ]; then
        log_message "No running containers found for $env_name"
        return 0
    fi
    
    # Check resource usage for each container
    for container in $containers; do
        container_name=$(docker inspect --format '{{.Name}}' $container | sed 's/\///')
        cpu_usage=$(docker stats --no-stream --format "{{.CPUPerc}}" $container)
        mem_usage=$(docker stats --no-stream --format "{{.MemPerc}}" $container)
        
        # Remove the % sign from percentages
        cpu_value=$(echo $cpu_usage | sed 's/%//')
        mem_value=$(echo $mem_usage | sed 's/%//')
        
        if (( $(echo "$cpu_value > 90" | bc -l) )); then
            log_alert "Container $container_name CPU usage critical: $cpu_usage"
        elif (( $(echo "$cpu_value > 75" | bc -l) )); then
            log_message "Container $container_name CPU usage high: $cpu_usage"
        fi
        
        if (( $(echo "$mem_value > 90" | bc -l) )); then
            log_alert "Container $container_name memory usage critical: $mem_usage"
        elif (( $(echo "$mem_value > 75" | bc -l) )); then
            log_message "Container $container_name memory usage high: $mem_usage"
        fi
    done
    
    log_message "Resource check complete for $env_name"
    return 0
}

# Function to check container logs for errors
check_container_logs() {
    local env_dir=$1
    local env_name=$2
    
    log_message "Checking container logs for errors in $env_name..."
    
    if [ ! -d "$env_dir" ]; then
        log_message "$env_name environment directory does not exist"
        return 0
    fi
    
    cd $env_dir
    
    # Define error patterns to look for
    error_patterns=("ERROR" "FATAL" "Exception" "OOMKilled" "panic:" "failed with exit code")
    
    # Get list of running containers
    local containers=$(docker compose ps -q)
    
    if [ -z "$containers" ]; then
        log_message "No running containers found for $env_name"
        return 0
    fi
    
    # Check logs of each container for the last 5 minutes
    for container in $containers; do
        container_name=$(docker inspect --format '{{.Name}}' $container | sed 's/\///')
        
        # Get recent logs (last 5 minutes)
        since_time="5m"
        recent_logs=$(docker logs --since $since_time $container 2>&1)
        
        # Check for error patterns
        for pattern in "${error_patterns[@]}"; do
            if echo "$recent_logs" | grep -q "$pattern"; then
                error_count=$(echo "$recent_logs" | grep -c "$pattern")
                log_alert "Found $error_count instances of '$pattern' in $container_name logs (last 5m)"
                
                # Extract a sample of the errors (up to 3 lines)
                error_sample=$(echo "$recent_logs" | grep "$pattern" | head -3)
                log_alert "Sample errors from $container_name:"
                log_alert "$error_sample"
            fi
        done
    done
    
    log_message "Log check complete for $env_name"
    return 0
}

# Function to check database health
check_database_health() {
    local env_dir=$1
    local env_name=$2
    
    log_message "Checking database health for $env_name..."
    
    if [ ! -d "$env_dir" ]; then
        log_message "$env_name environment directory does not exist"
        return 0
    fi
    
    cd $env_dir
    
    # Check if Postgres container is running
    if ! docker compose ps postgres | grep -q "Up"; then
        log_alert "Postgres container is not running for $env_name!"
        return 1
    fi
    
    # Run a simple query to check database responsiveness
    if ! docker compose exec -T postgres pg_isready -U retool > /dev/null 2>&1; then
        log_alert "Postgres database is not responding for $env_name!"
        return 1
    fi
    
    # Check database size
    db_size=$(docker compose exec -T postgres psql -U retool -c "SELECT pg_size_pretty(pg_database_size('retool'));" | grep -v "pg_size_pretty" | grep -v "row" | tr -d '[:space:]')
    log_message "Database size for $env_name: $db_size"
    
    # Check connection count
    conn_count=$(docker compose exec -T postgres psql -U retool -c "SELECT count(*) FROM pg_stat_activity;" | grep -v "count" | grep -v "row" | tr -d '[:space:]')
    
    if [ "$conn_count" -gt 100 ]; then
        log_alert "High number of database connections for $env_name: $conn_count"
    else
        log_message "Database connection count for $env_name: $conn_count"
    fi
    
    log_message "Database is healthy for $env_name"
    return 0
}

# Function to check API health
check_api_health() {
    local env_dir=$1
    local env_name=$2
    local port=$3
    
    log_message "Checking API health for $env_name on port $port..."
    
    if [ ! -d "$env_dir" ]; then
        log_message "$env_name environment directory does not exist"
        return 0
    fi
    
    # Try to connect to the API endpoint
    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$port/api/checkHealth 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        log_message "API is responding normally for $env_name"
        return 0
    else
        log_alert "API health check failed for $env_name. Response code: $response"
        return 1
    fi
}

# Function to check if environment needs an update
check_update_availability() {
    local env_name=$1
    local current_version=$2
    local policy=$3
    
    log_message "Checking for updates for $env_name (current: $current_version, policy: $policy)..."
    
    # Get the latest version based on policy
    latest_version=$(/opt/retool-config/get_version.sh $env_name $policy)
    
    if [ "$latest_version" != "$current_version" ]; then
        log_message "Update available for $env_name: $current_version -> $latest_version"
        return 0
    else
        log_message "No updates available for $env_name. Current version is latest."
        return 1
    fi
}

# Perform all health checks for an environment
check_environment_health() {
    local env_name=$1
    local env_dir=$2
    local port=$3
    local policy=$4
    
    log_message "===== Starting health check for $env_name environment ====="
    
    if [ ! -d "$env_dir" ]; then
        log_message "$env_name environment directory does not exist"
        return 0
    fi
    
    # Check if Dockerfile exists
    if [ ! -f "$env_dir/Dockerfile" ]; then
        log_message "$env_name environment doesn't have a Dockerfile"
        return 0
    fi
    
    # Get current version
    current_version=$(grep "ARG VERSION=" $env_dir/Dockerfile | cut -d= -f2)
    log_message "Current version: $current_version"
    
    # Perform checks
    check_container_resources $env_dir $env_name
    check_container_logs $env_dir $env_name
    check_database_health $env_dir $env_name
    check_api_health $env_dir $env_name $port
    check_update_availability $env_name "$current_version" $policy
    
    log_message "===== Completed health check for $env_name environment ====="
}

# Main function
main() {
    log_message "Starting Retool health monitoring"
    
    # Ensure log files exist and are writable
    touch $LOG_FILE $ALERT_FILE
    chmod 644 $LOG_FILE $ALERT_FILE
    
    # Check system-wide health
    check_disk_space
    check_docker_health
    
    # Check individual environments
    if [ "$1" = "all" ] || [ "$1" = "dev" ]; then
        check_environment_health "development" $DEV_DIR 3000 $DEV_VERSION_POLICY
    fi
    
    if [ "$1" = "all" ] || [ "$1" = "staging" ]; then
        check_environment_health "staging" $STAGING_DIR 3002 $STAGING_VERSION_POLICY
    fi
    
    if [ "$1" = "all" ] || [ "$1" = "prod" ]; then
        check_environment_health "production" $PROD_DIR 3001 $PROD_VERSION_POLICY
    fi
    
    log_message "Health monitoring complete"
}

# Run the main function with the provided argument
main ${1:-"all"}
