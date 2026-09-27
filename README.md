# swarm-backup

Weekly backup job for the 3-node Docker Swarm. Deployed as Portainer stack 21 (`swarm-backup`),
a **global** service, so one task runs on each node.

Each run: tar of each service's data on that node, plus a MariaDB dump and an InfluxDB backup →
restic repo on Unraid (`/mnt/unraid-backup`), then an rclone mirror of the restic repo (and HA
backups) to OneDrive. The result is pushed to the Uptime Kuma push monitor "swarm-0N Backup".

## Layout

| Path | What | Where it lives in production |
|---|---|---|
| `backup-fixed.sh` | the backup script that actually runs | `/mnt/dockerswarmvol/swarm-backup/backup-fixed.sh`, bind-mounted over `/usr/local/bin/backup.sh` |
| `start-fixed.sh` | container entrypoint (cron setup) | `/mnt/dockerswarmvol/swarm-backup/start-fixed.sh`, bind-mounted over `/start.sh` |
| `image/` | build context of the image `rormeister/swarm-backup` (built 2025-07-14; its `backup.sh`/`start.sh` are overridden by the mounts above) | `/mnt/dockerswarmvol/swarm-backup/container/` |
| `stack/docker-compose.yml` | the Portainer stack file | Portainer stack 21 (update via `PUT /api/stacks/21?endpointId=5`) |
| `rclone.conf.example` | shape of the rclone config | real file in `rclone-dir/` on Gluster, not in git |

The restic binary is mounted from `/mnt/dockerswarmvol/swarm-backup/bin/restic` (not in git).
The image is pinned by digest in the stack; after a rebuild, update the digest there.

## Secrets (never commit them)

- `MYSQL_ROOT_PASSWORD`, `INFLUXDB_TOKEN`, `RESTIC_PASSWORD`: Docker Swarm
  secrets, read from `/run/secrets/*`.
- rclone OneDrive token: `rclone-dir/rclone.conf` on Gluster.
- **Kuma push tokens** (lines 241–243 of `backup-fixed.sh`) are `REDACTED_SEE_README` in git.
  The production copy holds the real values; copy them from there (or from Kuma: push monitors
  "swarm-0N Backup") when deploying from this repo.

## Deploy

1. Edit here, review `git diff`.
2. Copy the scripts to `/mnt/dockerswarmvol/swarm-backup/` on any swarm node (Gluster), keeping the
   production Kuma tokens.
3. Stack changes: update stack 21 through the Portainer API so Portainer stays in sync.
