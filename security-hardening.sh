#!/bin/bash

# Security hardening script for Retool environments
source /opt/retool-config/environments.conf

# Function to secure an environment
secure_environment() {
    local env_name=$1
    local env_dir=$2
    
    echo "Securing $env_name environment..."
    
    # Ensure docker.env has secure settings
    cd $env_dir
    
    # Disable cookie insecure for production and staging
    if [ "$env_name" != "development" ]; then
        sed -i '/COOKIE_INSECURE=true/d' docker.env
        echo "COOKIE_SECURE=true" >> docker.env
    fi
    
    # Ensure strong JWT secret
    if grep -q "JWT_SECRET=" docker.env; then
        current_secret=$(grep "JWT_SECRET=" docker.env | cut -d= -f2)
        if [ ${#current_secret} -lt 32 ]; then
            # Generate a stronger secret
            new_secret=$(openssl rand -hex 32)
            sed -i "s/JWT_SECRET=.*/JWT_SECRET=$new_secret/" docker.env
            echo "Updated JWT_SECRET with stronger value"
        fi
    fi
    
    # Ensure HTTPS is configured for production
    if [ "$env_name" = "production" ]; then
        if grep -q "STAGE=local" docker-compose.yml; then
            sed -i 's/STAGE: "local"/STAGE: "production"/' docker-compose.yml
            echo "Updated HTTPS portal to use production certificates"
        fi
    fi
    
    echo "Security hardening complete for $env_name environment"
}

# Apply security to appropriate environments
if [ "$1" = "all" ]; then
    secure_environment "production" $PROD_DIR
    secure_environment "staging" $STAGING_DIR
    secure_environment "development" $DEV_DIR
elif [ "$1" = "prod" ]; then
    secure_environment "production" $PROD_DIR
elif [ "$1" = "staging" ]; then
    secure_environment "staging" $STAGING_DIR
elif [ "$1" = "dev" ]; then
    secure_environment "development" $DEV_DIR
else
    echo "Usage: security-hardening.sh [prod|staging|dev|all]"
    exit 1
fi
