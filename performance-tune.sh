#!/bin/bash

# Performance tuning script for Retool environments
source /opt/retool-config/environments.conf

# Function to tune an environment
tune_environment() {
    local env_name=$1
    local env_dir=$2
    local memory_limit=$3  # in GB
    local db_connections=$4
    
    echo "Tuning $env_name environment..."
    
    cd $env_dir
    
    # Update memory limits in docker-compose.yml
    memory_mb=$((memory_limit * 1024))
    
    # Add memory limits to appropriate services
    sed -i "/service: api/a\\    deploy:\\      resources:\\        limits:\\          memory: ${memory_mb}M" docker-compose.yml
    
    # Update database connection settings
    if grep -q "POSTGRES_POOL_MAX_SIZE" docker.env; then
        sed -i "s/POSTGRES_POOL_MAX_SIZE=.*/POSTGRES_POOL_MAX_SIZE=$db_connections/" docker.env
    else
        echo "POSTGRES_POOL_MAX_SIZE=$db_connections" >> docker.env
    fi
    
    # Update query timeout for better handling of long-running queries
    if grep -q "DBCONNECTOR_QUERY_TIMEOUT_MS" docker.env; then
        sed -i "s/DBCONNECTOR_QUERY_TIMEOUT_MS=.*/DBCONNECTOR_QUERY_TIMEOUT_MS=300000/" docker.env
    else
        echo "DBCONNECTOR_QUERY_TIMEOUT_MS=300000" >> docker.env
    fi
    
    echo "Performance tuning complete for $env_name environment"
    echo "Restart the environment to apply changes: manage_retool.sh restart $env_name"
}

# Apply tuning to specified environment
if [ "$1" = "prod" ]; then
    tune_environment "production" $PROD_DIR 4 100
elif [ "$1" = "staging" ]; then
    tune_environment "staging" $STAGING_DIR 2 50
elif [ "$1" = "dev" ]; then
    tune_environment "development" $DEV_DIR 2 20
else
    echo "Usage: performance-tune.sh [prod|staging|dev]"
    echo "Example: performance-tune.sh prod"
    exit 1
fi
