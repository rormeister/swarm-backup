#!/bin/bash

NODE_NAME=$(cat /etc/hostname)

# Run backup immediately on startup
echo "[*] Launching immediate backup for $NODE_NAME"
/usr/local/bin/backup.sh 2>&1 | tee -a /var/log/backup-${NODE_NAME}.log

# Determine a unique hour between 0–23 for staggered backups
CRON_HOUR=$(( $(echo "$NODE_NAME" | cksum | awk '{print $1}') % 24 ))
CRON_MINUTE=$(( RANDOM % 30 ))  # 0-29 minutes

echo "[*] Scheduling cron for every day at ${CRON_HOUR}:${CRON_MINUTE}"

# Set up cron job with dynamic time per node
echo "${CRON_MINUTE} ${CRON_HOUR} * * * /usr/local/bin/backup.sh >> /var/log/backup-${NODE_NAME}.log 2>&1" > /etc/crontabs/root

# Start cron in foreground
crond -f