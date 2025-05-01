# Retool Disaster Recovery Procedures

## Database Failure Recovery

1. Stop the affected environment:
/opt/retool-config/manage_retool.sh stop [environment]

2. List available backups:
/opt/retool-config/manage_retool.sh list-backups [environment]

3. Roll back to the most recent working backup:
/opt/retool-config/manage_retool.sh rollback [environment] [backup_id]

## Server Failure Recovery

1. Set up a new server with the same specifications
2. Install Docker and Docker Compose
3. Clone the Retool configuration repository
4. Copy the backup directory from backup storage
5. Run the recovery script:
/opt/retool-config/disaster-recovery.sh [environment]

## Version Upgrade Failure

1. Check the logs to identify the issue:
/opt/retool-config/manage_retool.sh logs [environment]

2. Roll back to the previous version:
/opt/retool-config/manage_retool.sh rollback [environment] [pre_upgrade_backup_id]

## Complete Environment Recovery

For complete recovery from scratch:

1. Create the environment:
/opt/retool-config/manage_retool.sh create [environment]

2. Restore from the latest backup:
/opt/retool-config/manage_retool.sh rollback [environment] [backup_id]

