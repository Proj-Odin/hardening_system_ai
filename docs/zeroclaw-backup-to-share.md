# ZeroClaw Backup To Share

This repository includes `scripts/backup-zeroclaw-to-share.sh`, a Bash backup utility for Alpine Linux ZeroClaw hosts. It backs up a ZeroClaw install from `/home/admin/.zeroclaw` to a mounted share such as `/mnt/qnap/zeroclaw-backups` or `/mnt/share/zeroclaw-backups`.

## What Gets Backed Up

Each run creates a timestamped directory:

```text
${DEST_ROOT}/${HOST}/${YYYYMMDD_HHMMSS}
```

The backup directory contains:

- `zeroclaw-full.tar.gz`, a compressed archive of the full `.zeroclaw` directory.
- `config.toml`, copied separately when present.
- `brain.db.backup`, created with SQLite's native `.backup` command when a database is found.
- `brain.sql`, a human-readable SQL dump when a database is found.
- `sqlite_integrity_check.txt`, containing the `PRAGMA integrity_check;` result for the SQLite backup copy.
- `manifest.txt`, with host, paths, retention, database path, and ZeroClaw version when available.
- `SHA256SUMS.txt`, with checksums for the files written by the backup.
- `WARNING-no-sqlite-db.txt`, only when no SQLite database is found.

The script prefers `/home/admin/.zeroclaw/workspace/memory/brain.db`. If that file is not present, it searches for the first `*.db`, `*.sqlite`, or `*.sqlite3` file under `.zeroclaw`. Set `DB_PATH=/path/to/database` to override detection.

## Install Packages On Alpine

```sh
sudo apk add --no-cache bash sqlite tar gzip findutils coreutils
```

By default, `AUTO_INSTALL_DEPS=0`. The script validates required commands and exits before creating backup files if any are missing, so it does not unexpectedly modify the system.

To let the script install missing dependencies on Alpine Linux, opt in explicitly:

```sh
AUTO_INSTALL_DEPS=1 DEST_ROOT=/mnt/qnap/zeroclaw-backups SHARE_MOUNT=/mnt/qnap ./scripts/backup-zeroclaw-to-share.sh
```

Automatic installation is Alpine-only. The script checks for `/etc/alpine-release` or `apk`, uses `apk add --no-cache bash sqlite tar gzip findutils coreutils`, and uses `sudo` when it is not running as root. It does not attempt `apt`, `yum`, `dnf`, or systemd-based setup.

## Run A Backup

```sh
DEST_ROOT=/mnt/qnap/zeroclaw-backups SHARE_MOUNT=/mnt/qnap ./scripts/backup-zeroclaw-to-share.sh
```

By default, the script uses:

```sh
ZC_USER=admin
ZC_HOME=/home/${ZC_USER}
ZC_DIR=${ZC_HOME}/.zeroclaw
DEST_ROOT=/mnt/share/zeroclaw-backups
SHARE_MOUNT=/mnt/share
REQUIRE_MOUNT=1
RETENTION_DAYS=30
AUTO_INSTALL_DEPS=0
```

When `REQUIRE_MOUNT=1`, the script refuses to write backups unless `SHARE_MOUNT` is listed in `/proc/mounts`. Use `REQUIRE_MOUNT=0` only for testing or for a destination that is intentionally not a mounted share.

To preview actions without writing backup files:

```sh
DRY_RUN=1 DEST_ROOT=/mnt/qnap/zeroclaw-backups SHARE_MOUNT=/mnt/qnap ./scripts/backup-zeroclaw-to-share.sh
```

## Cron Example

```cron
30 2 * * * DEST_ROOT=/mnt/qnap/zeroclaw-backups SHARE_MOUNT=/mnt/qnap /home/admin/path-to-repo/scripts/backup-zeroclaw-to-share.sh >> /home/admin/zeroclaw-backup.log 2>&1
```

## Restore Notes

Stop ZeroClaw before restoring files into `/home/admin/.zeroclaw`. Do not restore the full tarball over a running ZeroClaw process.

To restore the full `.zeroclaw` directory, move the existing directory aside first, then extract `zeroclaw-full.tar.gz` from a trusted backup.

To restore the SQLite database, prefer `brain.db.backup`. Stop ZeroClaw, place the restored database back at the expected database path, then start ZeroClaw again.

Use `brain.sql` as a human-readable recovery fallback. For example, it can be loaded into a new SQLite database with:

```sh
sqlite3 restored-brain.db < brain.sql
```

## Security Warning

Backups are sensitive. `config.toml` may contain API keys, tokens, service credentials, or other secrets, and the database may contain workspace memory or operational data.

Store the backup share on access-controlled storage, restrict read access, and avoid copying backups to less trusted systems.

## Troubleshooting

`SHARE_MOUNT is not mounted`: Mount the share first, confirm it appears in `/proc/mounts`, and make sure `SHARE_MOUNT` matches the mounted path exactly.

`Missing required command(s)`: Install the listed commands before running the backup. If `sqlite3` is missing, the script prints `sudo apk add --no-cache sqlite` and the full recommended Alpine package command. On Alpine only, you can rerun with `AUTO_INSTALL_DEPS=1` to let the script install the required packages.

`Permission denied`: Run as a user that can read `/home/admin/.zeroclaw` and write to `DEST_ROOT`. Root is not required unless your filesystem permissions require it.

`SQLite backup failed integrity check`: Keep the failed backup directory for inspection, check storage health, and retry after confirming the source database is readable. Do not restore from a backup that fails integrity checks.

`ZeroClaw appears to be running`: This is a warning, not a failure. The SQLite `.backup` output is designed for a live database, but the full tarball may capture live file state. For the most conservative full-directory backup, stop ZeroClaw before running the script.

`Another backup appears to be running`: The lock directory `/tmp/zeroclaw-backup.lock` already exists. Check whether another backup process is active before removing a stale lock.
