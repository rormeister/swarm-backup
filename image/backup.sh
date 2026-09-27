#!/bin/bash
set -euo pipefail

#########################################################
# Variables
NODE_NAME=$(cat /etc/hostname)
ROTATE_DAYS=7 # Days to keep rotated logs
RETENTION_DAYS=7 # Days to keep backups on OneDrive and locally
REMOTE_NAME="onedrive" # Name of the rclone remote configured for OneDrive
REMOTE_BASE_PATH="swarm-backups" # Base directory on OneDrive without slashes
REMOTE_PATH="${REMOTE_BASE_PATH}/${NODE_NAME}/$(date +%F)"
LOGFILE="/var/log/backup-${NODE_NAME}.log"
TARGET_DIR="/mnt/unraid-backup/swarm-backups/${NODE_NAME}/$(date +%F)"
SELF_CONTAINER_ID=$(hostname)
SKIP_CONTAINERS_REGEX="adminer|cloudflared" # Containers to skip
SKIP_PATHS_REGEX="cache|transcode|thumbnails|downloads|metadata|tmp|logs|/mnt/unraid-backup" # Paths to skip in backups
#########################################################

# Rotate log file
if [ -f "$LOGFILE" ]; then
  find "$(dirname "$LOGFILE")" -name "$(basename "$LOGFILE").*" -mtime +$ROTATE_DAYS -delete
  mv "$LOGFILE" "$LOGFILE.$(date +%F)"
fi
touch "$LOGFILE"

echo "[*] Starting Swarm Backup: $(date)" | tee -a "$LOGFILE"

mkdir -p "$TARGET_DIR"

while read -r service; do
  stack="${service%%_*}"
  svc="${service#*_}"

  if echo "$service" | grep -iqE "$SKIP_CONTAINERS_REGEX"; then
    echo "[~] Skipping service due to exclude pattern: $service" | tee -a "$LOGFILE"
    continue
  fi

  container_id=$(docker ps --filter "name=${service}" --format "{{.ID}}" | head -n1)
  if [ "$container_id" = "$SELF_CONTAINER_ID" ] || [ -z "$container_id" ]; then
    echo "[~] Skipping self or missing container on host for service: $service" | tee -a "$LOGFILE"
    continue
  fi

  volumes=$(docker inspect "$container_id" --format '{{range .Mounts}}{{.Source}} {{end}}')
  for volume_path in $volumes; do
    if [[ "$volume_path" != /mnt/dockerswarmvol/* ]]; then
      echo "[-] Skipping volume $volume_path (not under /mnt/dockerswarmvol)" | tee -a "$LOGFILE"
      continue
    fi

    if echo "$volume_path" | grep -iqE "$SKIP_PATHS_REGEX"; then
      echo "[-] Skipping volume path $volume_path due to exclude pattern" | tee -a "$LOGFILE"
      continue
    fi

    [ -d "$volume_path" ] || { echo "[-] Volume path $volume_path not accessible"; continue; }

    name="$(basename "$volume_path")"
    archive_file="$TARGET_DIR/${stack}_${svc}_${name}.tar.gz"
    echo "[*] Starting backup of $volume_path..." | tee -a "$LOGFILE"
    tar --exclude='*.log' --warning=no-file-changed -czf "$archive_file" -C "$volume_path" . 2>>"$LOGFILE" || echo "[!] Failed to archive $volume_path" | tee -a "$LOGFILE"

    if [ -f "$archive_file" ]; then
      size=$(du -h "$archive_file" | cut -f1)
      echo "[✔] Backed up $archive_file ($size)" | tee -a "$LOGFILE"
    fi
  done

  case "$service" in
    *vaultwarden*)
      docker exec "$container_id" /data/db.sqlite3 ".backup '/data/db-backup.sqlite3'" 2>>"$LOGFILE" || echo "[!] Vaultwarden backup command failed" | tee -a "$LOGFILE"
      docker cp "$container_id:/data/db-backup.sqlite3" "$TARGET_DIR/vaultwarden_backup.sqlite3" 2>>"$LOGFILE"  && echo "[✔] Vaultwarden database backup complete" | tee -a "$LOGFILE" || echo "[!] Vaultwarden backup failed" | tee -a "$LOGFILE"
      ;;
    *immich_postgres*)
      docker exec -e PGPASSWORD="$IMMICH_DB_PASSWORD" "$container_id" pg_dump -U postgres immich > "$TARGET_DIR/immich_backup.sql" 2>>"$LOGFILE"  && echo "[✔] Immich database backup complete" | tee -a "$LOGFILE" || echo "[!] Immich pg_dump failed" | tee -a "$LOGFILE"
      ;;
    *mariadb*)
      docker exec "$container_id" sh -c "mariadb-dump -uroot -p$MYSQL_ROOT_PASSWORD --single-transaction --all-databases" > "$TARGET_DIR/mariadb_backup.sql" 2>>"$LOGFILE" && echo "[✔] MariaDB database backup complete" | tee -a "$LOGFILE" || echo "[!] MariaDB dump failed for $service" | tee -a "$LOGFILE"
      ;;
    *influxdb*)
      docker exec "$container_id" influx backup -token "$INFLUXDB_TOKEN" /tmp/influx_backup 2>>"$LOGFILE" || echo "[!] InfluxDB backup command failed" | tee -a "$LOGFILE"
      docker cp "$container_id:/tmp/influx_backup" "$TARGET_DIR/influxdb_backup" 2>>"$LOGFILE" || echo "[!] InfluxDB copy failed" | tee -a "$LOGFILE"
      ;;
    *portainer_portainer*)
      docker cp "$container_id:/data" "$TARGET_DIR/portainer_data" 2>>"$LOGFILE" && echo "[✔] Portainer backup complete" | tee -a "$LOGFILE" || echo "[!] Portainer backup failed" | tee -a "$LOGFILE"
      ;;
  esac

done < <(docker service ls --format '{{.Name}}')

# Upload to OneDrive using rclone
echo "[*] Uploading backup to OneDrive..." | tee -a "$LOGFILE"
rclone copy "$TARGET_DIR" "${REMOTE_NAME}:${REMOTE_PATH}" --config /rclone/rclone.conf -v 2>>"$LOGFILE" && echo "[✔] OneDrive backup complete" | tee -a "$LOGFILE" || echo "[!] OneDrive backup FAILED" | tee -a "$LOGFILE"

# --- Clean up old backups on OneDrive ---
echo "[*] Cleaning up OneDrive backups older than ${RETENTION_DAYS} days..." | tee -a "$LOGFILE"
rclone delete --rmdirs --min-age ${RETENTION_DAYS}d "${REMOTE_NAME}:${REMOTE_BASE_PATH}/${NODE_NAME}" --config /rclone/rclone.conf -v 2>>"$LOGFILE"
#rclone rmdirs --leave-root --min-age ${RETENTION_DAYS}d "${REMOTE_NAME}:${REMOTE_BASE_PATH}" --config /rclone/rclone.conf -v 2>>"$LOGFILE"
echo "[✔] OneDrive cleanup complete" | tee -a "$LOGFILE"

echo "[*] Cleaning up local backups older than ${RETENTION_DAYS} days..." | tee -a "$LOGFILE"
find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} \;
echo "[✔] Local cleanup complete" | tee -a "$LOGFILE"

echo "[*] Swarm Backup completed: $(date)" | tee -a "$LOGFILE"