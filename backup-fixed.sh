#!/bin/bash
set -euo pipefail

# Prevent two backup runs overlapping on the same node (e.g. an immediate
# manual/startup run colliding with the scheduled cron run). Container-local
# path, so this only guards runs on this node, not across nodes.
exec 200>/tmp/backup.lock
if ! flock -n 200; then
  echo "[!] Another backup run is already in progress on this node - exiting"
  exit 1
fi

#########################################################
# Secrets (mounted via Docker Swarm secrets at /run/secrets/<name>,
# falling back to an env var of the same name if not mounted)
MYSQL_ROOT_PASSWORD="$(cat /run/secrets/MYSQL_ROOT_PASSWORD 2>/dev/null || echo "${MYSQL_ROOT_PASSWORD:-}")"
INFLUXDB_TOKEN="$(cat /run/secrets/INFLUXDB_TOKEN 2>/dev/null || echo "${INFLUXDB_TOKEN:-}")"
# Restic needs its repository password as a FILE, not a value - point it
# straight at the mounted secret rather than reading it into a shell var,
# so it never appears in this process's environment at all. Falls back to
# writing the env var to a private temp file for non-Swarm/local runs.
RESTIC_PASSWORD_FILE="/run/secrets/RESTIC_PASSWORD"
if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
  RESTIC_PASSWORD_FILE="/tmp/.restic_password"
  echo "${RESTIC_PASSWORD:-}" > "$RESTIC_PASSWORD_FILE"
  chmod 600 "$RESTIC_PASSWORD_FILE"
fi

#########################################################
# Variables
NODE_NAME=$(cat /etc/hostname)
# Backups now run weekly (see start.sh), not daily - retention below is
# scaled up accordingly so it still keeps multiple recovery points instead
# of being deleted almost as soon as it's written.
ROTATE_DAYS=60 # Days to keep rotated logs (~8 weekly runs)
# Local retention is short - these tar archives are now only for fast local
# recovery of the last few weeks; restic (below) is the offsite/long-term
# copy, so there's no separate remote retention for this method any more.
LOCAL_RETENTION_DAYS=28 # Days to keep backups on the local NAS (~4 weekly runs)
REMOTE_NAME="onedrive" # Name of the rclone remote configured for OneDrive (used by restic's mirror and the HA sync below)
# Home Assistant writes its own backups directly to the NAS share (not into
# any node's /mnt/dockerswarmvol volumes), so the per-service loop below
# never sees them, and they're not captured by PBS's VM-level backup of the
# HA VM either (they live outside that VM's virtual disk). Right now B2 is
# their only offsite copy; sync them to OneDrive here instead. Not
# node-specific data, so this only runs on one node to avoid 3x uploads.
HA_LOCAL_DIR="/mnt/unraid-backup/HomeAssistant"
HA_REMOTE_PATH="home-assistant-backups"
HA_SYNC_NODE="docker-swarm-01"
LOGFILE="/var/log/backup-${NODE_NAME}.log"
NODE_BACKUP_DIR="/mnt/unraid-backup/swarm-backups/${NODE_NAME}"
TARGET_DIR="${NODE_BACKUP_DIR}/$(date +%F)"
SELF_CONTAINER_ID=$(hostname)
SKIP_CONTAINERS_REGEX="adminer|cloudflared" # Containers to skip
SKIP_PATHS_REGEX="cache|transcode|thumbnails|downloads|metadata|tmp|logs|/mnt/unraid-backup" # Paths to skip in backups
# Restic is now the sole offsite/long-retention backup method (cut over
# from the trial after 2 clean weeks - see the "restic backup" section
# below). One canonical repo per node on the NAS; OneDrive gets a straight
# rclone mirror of that repo directory rather than its own independent
# restic repo, so deduplication only has to happen once.
RESTIC_BIN="/usr/local/bin/restic"
RESTIC_LOCAL_REPO="/mnt/unraid-backup/restic-repo/${NODE_NAME}"
RESTIC_REMOTE_REPO_PATH="swarm-backups-restic/${NODE_NAME}"
RESTIC_KEEP_WEEKLY=26 # ~6 months of weekly snapshots - the primary offsite retention now
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
    # GNU tar exits 1 (not 2) when a file changed while being read - common
    # for actively-running apps like Radarr/Sonarr writing to their own
    # sqlite db mid-backup. The archive is still created and usable in that
    # case, so only treat exit codes >1 as a real failure.
    if tar --exclude='*.log' --warning=no-file-changed -czf "$archive_file" -C "$volume_path" . 2>>"$LOGFILE"; then
      tar_rc=0
    else
      tar_rc=$?
    fi
    if [ "$tar_rc" -eq 1 ]; then
      echo "[~] $volume_path had files change mid-backup (harmless for an active app)" | tee -a "$LOGFILE"
    elif [ "$tar_rc" -gt 1 ]; then
      echo "[!] Failed to archive $volume_path (tar exit $tar_rc)" | tee -a "$LOGFILE"
    fi

    if [ -f "$archive_file" ]; then
      size=$(du -h "$archive_file" | cut -f1)
      echo "[✔] Backed up $archive_file ($size)" | tee -a "$LOGFILE"
    fi
  done

  case "$service" in
    # Vaultwarden special case removed: the vaultwarden/server image has no
    # sqlite3 CLI, so a proper hot-consistent ".backup" snapshot isn't
    # achievable without adding tooling to that image (not done here - it's
    # a password manager). The generic per-service tar above already
    # captures the whole /data volume, including db.sqlite3, with the same
    # best-effort consistency as every other live service in this script.
    *mariadb*)
      # MYSQL_PWD (env var, not a -p CLI arg) keeps the password out of the
      # process list (`ps aux` inside the container would otherwise show it).
      docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$container_id" sh -c "mariadb-dump -uroot --single-transaction --all-databases" > "$TARGET_DIR/mariadb_backup.sql" 2>>"$LOGFILE" && echo "[✔] MariaDB database backup complete" | tee -a "$LOGFILE" || echo "[!] MariaDB dump failed for $service" | tee -a "$LOGFILE"
      ;;
    *influxdb*)
      # INFLUX_TOKEN (env var, not a -token CLI arg) keeps the token out of
      # the process list, same reasoning as MYSQL_PWD above.
      docker exec -e INFLUX_TOKEN="$INFLUXDB_TOKEN" "$container_id" influx backup /tmp/influx_backup 2>>"$LOGFILE" || echo "[!] InfluxDB backup command failed" | tee -a "$LOGFILE"
      docker cp "$container_id:/tmp/influx_backup" "$TARGET_DIR/influxdb_backup" 2>>"$LOGFILE" || echo "[!] InfluxDB copy failed" | tee -a "$LOGFILE"
      # Fixed: this dump was never cleaned up inside the influxdb container
      # after being copied out, so it accumulated ~8-12GB per day in that
      # container's own writable layer indefinitely (found this after it
      # filled a node's entire local disk to 100%). Safe to remove now that
      # it's been copied to $TARGET_DIR above.
      docker exec "$container_id" rm -rf /tmp/influx_backup 2>>"$LOGFILE" || echo "[!] Failed to clean up InfluxDB's own /tmp/influx_backup" | tee -a "$LOGFILE"
      ;;
    *portainer_portainer*)
      docker cp "$container_id:/data" "$TARGET_DIR/portainer_data" 2>>"$LOGFILE" && echo "[✔] Portainer backup complete" | tee -a "$LOGFILE" || echo "[!] Portainer backup failed" | tee -a "$LOGFILE"
      ;;
  esac

done < <(docker service ls --format '{{.Name}}')

# --- Restic backup (sole offsite/long-retention method as of the cutover) ---
# Deduplicated and encrypted, so a long retention window is far cheaper
# here than the old plain tar/rclone-to-OneDrive copies were. Still backs
# up $TARGET_DIR (this run's already-produced archives and dumps) rather
# than the raw source paths directly - that proved the mechanism out fine
# (repo init, backup, prune, offsite mirror, restore all verified working),
# but won't dedup as well as backing up raw paths would, since re-gzipping
# the same files each week rarely produces byte-identical output. Worth
# revisiting as a follow-up: feed restic the raw per-service paths (same
# list the tar loop above already walks) instead of the tar output.
export RESTIC_PASSWORD_FILE
if [ -x "$RESTIC_BIN" ] && [ -s "$RESTIC_PASSWORD_FILE" ]; then
  # Restic has no "init if missing" flag, so probe for an existing repo first.
  if ! "$RESTIC_BIN" -r "$RESTIC_LOCAL_REPO" snapshots >/dev/null 2>>"$LOGFILE"; then
    echo "[*] Initializing new restic repository at $RESTIC_LOCAL_REPO" | tee -a "$LOGFILE"
    "$RESTIC_BIN" -r "$RESTIC_LOCAL_REPO" init 2>>"$LOGFILE" || echo "[!] Restic repo init failed" | tee -a "$LOGFILE"
  fi

  echo "[*] Running restic backup of $TARGET_DIR..." | tee -a "$LOGFILE"
  "$RESTIC_BIN" -r "$RESTIC_LOCAL_REPO" backup "$TARGET_DIR" --tag "$(date +%F)" --host "$NODE_NAME" 2>>"$LOGFILE" \
    && echo "[✔] Restic backup complete" | tee -a "$LOGFILE" \
    || echo "[!] Restic backup failed" | tee -a "$LOGFILE"

  echo "[*] Pruning restic snapshots beyond ${RESTIC_KEEP_WEEKLY} weekly generations..." | tee -a "$LOGFILE"
  "$RESTIC_BIN" -r "$RESTIC_LOCAL_REPO" forget --keep-weekly "$RESTIC_KEEP_WEEKLY" --prune 2>>"$LOGFILE" \
    && echo "[✔] Restic prune complete" | tee -a "$LOGFILE" \
    || echo "[!] Restic prune failed" | tee -a "$LOGFILE"

  echo "[*] Mirroring restic repo to OneDrive..." | tee -a "$LOGFILE"
  timeout 60m rclone sync "$RESTIC_LOCAL_REPO" "${REMOTE_NAME}:${RESTIC_REMOTE_REPO_PATH}" --config /rclone/rclone.conf -v 2>>"$LOGFILE" \
    && echo "[✔] Restic OneDrive mirror complete" | tee -a "$LOGFILE" \
    || echo "[!] Restic OneDrive mirror failed" | tee -a "$LOGFILE"
else
  echo "[!] Restic unavailable (binary or password missing) - skipping restic backup this run" | tee -a "$LOGFILE"
fi

# Cutover complete: restic (above) is now the sole offsite/long-retention
# mechanism. The tar archives in $TARGET_DIR still get made (for fast local
# recovery, see LOCAL_RETENTION_DAYS below) but are no longer separately
# uploaded to OneDrive - that was duplicating restic's own OneDrive mirror
# and was on track to exceed OneDrive's 1TB cap by itself within months
# (node2's ~28GB/week alone, at the old 180-day retention, was ~850GB).

# --- Home Assistant's own backups: plain sync, not copy+cleanup like above.
# HA already rotates its own old backups out locally, so mirroring that
# with `sync` keeps OneDrive bounded automatically without needing a
# separate remote-retention pass.
if [ "$NODE_NAME" = "$HA_SYNC_NODE" ]; then
  echo "[*] Syncing Home Assistant's own backups to OneDrive..." | tee -a "$LOGFILE"
  if [ -d "$HA_LOCAL_DIR" ]; then
    timeout 30m rclone sync "$HA_LOCAL_DIR" "${REMOTE_NAME}:${HA_REMOTE_PATH}" --config /rclone/rclone.conf -v 2>>"$LOGFILE" \
      && echo "[✔] Home Assistant OneDrive sync complete" | tee -a "$LOGFILE" \
      || echo "[!] Home Assistant OneDrive sync FAILED" | tee -a "$LOGFILE"
  else
    echo "[!] Home Assistant backup dir $HA_LOCAL_DIR not found - skipping" | tee -a "$LOGFILE"
  fi
fi

echo "[*] Cleaning up local backups older than ${LOCAL_RETENTION_DAYS} days..." | tee -a "$LOGFILE"
# Fixed: this used to clean inside $TARGET_DIR (today's own dated folder,
# which never contains anything older than itself), so it never actually
# deleted anything. Target the parent per-node directory instead, which
# holds one subfolder per day.
find "$NODE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +${LOCAL_RETENTION_DAYS} -exec rm -rf {} \;
echo "[✔] Local cleanup complete" | tee -a "$LOGFILE"

echo "[*] Swarm Backup completed: $(date)" | tee -a "$LOGFILE"

# --- Report health to Uptime Kuma (push monitor) ---
# Summarizes the whole run by counting "[!]" failure lines already logged
# above, rather than tracking success/failure through every branch
# individually - so a red monitor actually means something went wrong,
# instead of requiring someone to read the log by hand.
# Fixed: previously all 3 nodes pushed to the same shared monitor/token, so
# whichever node's weekly run finished last silently determined the status
# shown for all three (a failure on one node could be masked by a later
# success on another) - same class of bug already fixed in disk-checker.sh.
# Each node now has its own Kuma push monitor. Tokens come from the Swarm
# secret KUMA_PUSH_TOKENS, one "<node-name>=<token>" line per node.
KUMA_PUSH_TOKEN="$(sed -n "s/^${NODE_NAME}=//p" /run/secrets/KUMA_PUSH_TOKENS 2>/dev/null | head -1 || true)"

if [ -z "$KUMA_PUSH_TOKEN" ]; then
  echo "[!] No Uptime Kuma push token mapped for node '$NODE_NAME' - skipping push" | tee -a "$LOGFILE"
else
  KUMA_PUSH_URL="http://192.168.50.35:3001/api/push/${KUMA_PUSH_TOKEN}"
  FAILURE_COUNT=$(grep -c '^\[!\]' "$LOGFILE" || true)
  if [ "${FAILURE_COUNT:-0}" -eq 0 ]; then
    curl -fsS --max-time 10 "${KUMA_PUSH_URL}?status=up&msg=OK&ping=" >/dev/null 2>&1 \
      || echo "[!] Uptime Kuma push failed" | tee -a "$LOGFILE"
  else
    curl -fsS --max-time 10 "${KUMA_PUSH_URL}?status=down&msg=${FAILURE_COUNT}_failures_see_log&ping=" >/dev/null 2>&1 \
      || echo "[!] Uptime Kuma push failed" | tee -a "$LOGFILE"
  fi
fi