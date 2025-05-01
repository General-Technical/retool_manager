#!/bin/bash

# Source environment configuration
source /opt/retool-config/environments.conf

# Number of backups to keep per environment
MAX_BACKUPS=${MAX_BACKUPS:-10}

# Rotate backups for an environment
rotate_env_backups() {
    ENV_NAME=$1
    
    # Count existing backups
    BACKUP_COUNT=$(find ${BACKUP_DIR} -name "${ENV_NAME}_*" -type d | wc -l)
    
    # Remove oldest backups if we have too many
    if [ $BACKUP_COUNT -gt $MAX_BACKUPS ]; then
        EXCESS=$((BACKUP_COUNT - MAX_BACKUPS))
        echo "Removing $EXCESS oldest backups for $ENV_NAME environment"
        
        find ${BACKUP_DIR} -name "${ENV_NAME}_*" -type d | sort | head -n $EXCESS | xargs rm -rf
    fi
}

# Rotate backups for all environments
rotate_env_backups "production"
rotate_env_backups "staging"
rotate_env_backups "development"

echo "Backup rotation complete. Current backup counts:"
echo "Production: $(find ${BACKUP_DIR} -name "production_*" -type d | wc -l)"
echo "Staging: $(find ${BACKUP_DIR} -name "staging_*" -type d | wc -l)"
echo "Development: $(find ${BACKUP_DIR} -name "development_*" -type d | wc -l)"
