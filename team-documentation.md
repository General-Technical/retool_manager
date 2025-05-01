# Retool Environment Management Guide

## Overview

This document describes how to manage our Retool environments using the custom management scripts.

## Environment Structure

We maintain three separate Retool environments:

- **Development**: For building and initial testing of apps
  - URL: https://retool-dev.example.com
  - Port: 3010
  - For: Developers and internal testing

- **Staging**: For QA and pre-production validation
  - URL: https://retool-staging.example.com
  - Port: 3020
  - For: QA team and stakeholder preview

- **Production**: For end-user access
  - URL: https://retool.example.com
  - Port: 3030
  - For: End users and production use

## Common Tasks

### Viewing Environment Status

```bash
/opt/retool-config/manage_retool.sh status [environment]
Deploying a New App

Build the app in the development environment
Export the app using the Retool UI
Promote to staging:
bash/opt/retool-config/manage_retool.sh promote dev-to-staging
/opt/retool-config/manage_retool.sh update staging

Test thoroughly in staging
Promote to production:
bash/opt/retool-config/manage_retool.sh promote staging-to-prod
/opt/retool-config/manage_retool.sh update prod


Updating Retool Version
bash/opt/retool-config/manage_retool.sh update [environment]
Handling Issues
If you encounter problems with any environment:

Check the health:
bash/opt/retool-config/manage_retool.sh health [environment]

View logs:
bash/opt/retool-config/manage_retool.sh logs [environment]

If necessary, roll back to a previous backup:
bash/opt/retool-config/manage_retool.sh list-backups [environment]
/opt/retool-config/manage_retool.sh rollback [environment] [backup_id]


Best Practices

Always test changes in development before promoting to staging
Create backups before major changes:
bash/opt/retool-config/manage_retool.sh backup [environment]

Do not edit configuration files directly; use the management scripts


## A Convenient Wrapper Command

For even easier usage, create a simple command wrapper:

```bash
sudo nano /usr/local/bin/retool
With content:
bash#!/bin/bash

# Simple wrapper for the Retool management script
/opt/retool-config/manage_retool.sh "$@"
Make it executable:
bashsudo chmod +x /usr/local/bin/retool
Now you can simply use commands like:
bashretool status all
retool update dev
retool health prod
