#!/bin/bash

# Backup script for all Retool environments
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/opt/retool-backups/$TIMESTAMP"

# Create backup directory
mkdir -p $BACKUP_DIR

# Function to backup an environment
backup_environment() {
    ENV_NAME=$1
    ENV_DIR=$2
    
    echo "Backing up $ENV_NAME environment..."
    
    # Create environment backup directory
    mkdir -p $BACKUP_DIR/$ENV_NAME
    
    # Backup configuration files
    cp $ENV_DIR/docker.env $BACKUP_DIR/$ENV_NAME/
    cp $ENV_DIR/retooldb.env $BACKUP_DIR/$ENV_NAME/
    cp $ENV_DIR/docker-compose.yml $BACKUP_DIR/$ENV_NAME/
    cp $ENV_DIR/Dockerfile $BACKUP_DIR/$ENV_NAME/
    
    # Backup database if environment is running
    if [ -d "$ENV_DIR" ] && cd $ENV_DIR && docker compose ps -q postgres &>/dev/null; then
        echo "Backing up database for $ENV_NAME..."
        docker compose exec -T postgres pg_dump -U retool retool > $BACKUP_DIR/$ENV_NAME/database.sql
    else
        echo "Postgres not running for $ENV_NAME, skipping database backup."
    fi
}

# Backup all environments
backup_environment "development" "/opt/retool-dev"
backup_environment "staging" "/opt/retool-staging"
backup_environment "production" "/opt/retool-prod"

# Create a symlink to the latest backup
rm -f /opt/retool-backups/latest
ln -s $BACKUP_DIR /opt/retool-backups/latest

echo "Backup completed successfully to $BACKUP_DIR"
