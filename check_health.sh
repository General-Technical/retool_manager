#!/bin/bash

# Source environment configuration
source /opt/retool-config/environments.conf

# Check health of an environment
check_env_health() {
    ENV_NAME=$1
    ENV_DIR=$2
    
    if [ ! -d "$ENV_DIR" ]; then
        echo "$ENV_NAME environment not found"
        return
    fi
    
    # Change to environment directory
    cd $ENV_DIR
    
    # Check for running containers
    RUNNING_COUNT=$(docker compose ps --status running | grep -v "NAME" | wc -l)
    EXPECTED_COUNT=11  # Adjust based on your docker-compose services
    
    if [ $RUNNING_COUNT -lt $EXPECTED_COUNT ]; then
        echo "WARNING: $ENV_NAME environment has only $RUNNING_COUNT/$EXPECTED_COUNT containers running"
        
        # List non-running containers
        echo "Non-running containers:"
        docker compose ps --status exited --status created --status restarting
    else
        echo "$ENV_NAME environment healthy: $RUNNING_COUNT containers running"
    fi
}

# Check all environments
check_env_health "Production" $PROD_DIR
check_env_health "Staging" $STAGING_DIR
check_env_health "Development" $DEV_DIR
