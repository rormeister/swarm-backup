#!/bin/bash

NODE_NAME=$(cat /etc/hostname)

# Run backup immediately on startup
echo "[*] Launching immediate backup for $NODE_NAME"
/usr/local/bin/backup.sh 2>&1 | tee -a /var/log/backup-${NODE_NAME}.log

# Determine a unique hour and minute for staggered backups, both derived
# deterministically from the node name so the schedule stays stable across
# restarts (previously CRON_MINUTE used $RANDOM, so every restart - even
# ones done purely for maintenance - silently moved the backup time).
NODE_HASH=$(echo "$NODE_NAME" | cksum | awk '{print $1}')
CRON_HOUR=$(( NODE_HASH % 24 ))
CRON_MINUTE=$(( (NODE_HASH / 24) % 60 ))
# Changed from daily to weekly. All nodes run on the same day (Sunday) so a
# week's backups are easy to reason about together, still staggered by hour
# so all 3 nodes don't hit the NAS/OneDrive at once.
CRON_DOW=0 # 0 = Sunday

echo "[*] Scheduling cron for every Sunday at ${CRON_HOUR}:${CRON_MINUTE}"

# Set up cron job with dynamic time per node
echo "${CRON_MINUTE} ${CRON_HOUR} * * ${CRON_DOW} /usr/local/bin/backup.sh >> /var/log/backup-${NODE_NAME}.log 2>&1" > /etc/crontabs/root

# Start cron in foreground
crond -f