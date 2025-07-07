# 🛠️ Project Suite: Retool Manager + Report Generator

This repository includes two independent toolsets:

- [`retool_manager`](#retool_manager): Infrastructure and container management tools for Retool.

---

## 📁 retool_manager

### Description
Shell scripts to deploy, monitor, backup, and auto-repair a self-hosted Retool instance. Designed for use on Docker-based Linux environments with automation support and hardening practices.

### Features
- Health checks  
- Full volume/data backups  
- Auto-repair for containers  
- Secure deployment  
- Container cleanup  
- Disaster recovery runbook  

### Requirements
- Linux host with Docker & Docker Compose  
- Bash v4+  
- `jq` JSON CLI tool  
- Sudo/root access  

---

### Quick Setup

```bash
git clone https://github.com/General-Technical/retool_manager.git
cd retool_manager
chmod +x *.sh
cp environments.conf.example environments.conf
# Edit environment config values
🔑 Key Scripts
Script/File	Description
check_health.sh	Full health validation of containers + volumes
auto-repair.sh	Auto-fix broken services
backup-all.sh	Backs up DB and Retool volumes
rotate_backups.sh	Cleans up old backups
performance-tune.sh	System/Docker performance optimizations
security-hardening.sh	System hardening for Docker/host security
disaster-recovery.md	Full restore procedures
deploy-dev.sh	Deploy dev containers easily
manage_retool*.sh	General control scripts (start/stop/update)

💻 Usage Example
bash
Copy
Edit
./check_health.sh
./backup-all.sh
./rotate_backups.sh
⏱️ Cron Sample
cron
Copy
Edit
0 4 * * * /path/to/retool_manager/check_health.sh && /path/to/backup-all.sh
