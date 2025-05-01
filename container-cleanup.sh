#!/bin/bash

# Script to clean up conflicting Docker containers
echo "Starting Docker container cleanup..."

# Source environment configuration
source /opt/retool-config/environments.conf

# Function to check if a container exists
container_exists() {
    docker ps -a --format '{{.Names}}' | grep -q "^$1$"
    return $?
}

# Function to safely stop and remove a container
safely_remove_container() {
    local container=$1
    
    echo "Attempting to remove container: $container"
    
    # Check if the container exists
    if container_exists $container; then
        # Check if the container is running
        if docker ps --format '{{.Names}}' | grep -q "^$container$"; then
            echo "Container $container is running. Stopping it..."
            docker stop $container
            
            # Wait a moment for the container to stop
            sleep 2
        fi
        
        # Remove the container
        echo "Removing container $container..."
        docker rm $container
        
        # Verify removal
        if container_exists $container; then
            echo "Failed to remove container $container!"
            return 1
        else
            echo "Container $container successfully removed."
            return 0
        fi
    else
        echo "Container $container does not exist. No action needed."
        return 0
    fi
}

# List of potential conflicting containers
conflicting_containers=(
    "temporal"
    "temporal-admin-tools"
    "temporal-ui"
    "retool-api-1"
    "retool-postgres-1"
    "retool-retooldb-postgres-1"
    "retool-code-executor-1"
    "retool-jobs-runner-1"
    "retool-workflows-backend-1"
    "retool-workflows-worker-1"
    "retool-https-portal-1"
)

# Remove conflicting containers
for container in "${conflicting_containers[@]}"; do
    safely_remove_container $container
done

echo "Container cleanup complete."
