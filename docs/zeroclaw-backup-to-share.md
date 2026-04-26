# ZeroClaw Backup To Share

## Overview

`scripts/backup-zeroclaw-to-share.sh` backs up a ZeroClaw install from `/home/admin/.zeroclaw` to a mounted share such as a local TrueNAS NFS or SMB/CIFS share, or uploads directly to TrueNAS SMB with `smbclient` when mounts are not available.

Mounted-share mode creates a timestamped directory:

```text
${DEST_ROOT}/${HOST}/${YYYYMMDD_HHMMSS}
```

No-mount SMB upload mode creates the same backup directory locally under `/tmp` first, then uploads the artifacts to `${SMB_URL}/${HOST}/${YYYYMMDD_HHMMSS}`.

The backup directory contains:

- `zeroclaw-full.tar.gz`, a compressed archive of the full `.zeroclaw` directory.
- `config.toml`, copied separately when present.
- `brain.db.backup`, created with SQLite's native `.backup` command when a database is found.
- `brain.sql`, a human-readable SQL dump when a database is found.
- `sqlite_integrity_check.txt`, containing the `PRAGMA integrity_check;` result for the SQLite backup copy.
- `manifest.txt`, with host, paths, retention, database path, and ZeroClaw version when available.
- `SHA256SUMS.txt`, with checksums for the files written by the backup.
- `WARNING-no-sqlite-db.txt`, only when no SQLite database is found.

SQLite's `.backup` command is used because ZeroClaw may be running while the script is called. The SQLite backup is designed to produce a consistent database copy even when the source database is active. The full tarball may still reflect live file state, so stop ZeroClaw first if you need the most conservative full-directory capture.

Backups are sensitive. `config.toml` may contain API keys, tokens, service credentials, or other secrets, and the database may contain workspace memory or operational data. Store backup shares on access-controlled storage.

The script prefers `/home/admin/.zeroclaw/workspace/memory/brain.db`. If that file is not present, it searches for the first `*.db`, `*.sqlite`, or `*.sqlite3` file under `.zeroclaw`. Set `DB_PATH=/path/to/database` to override detection.

## Alpine Dependencies

Manual install:

```sh
sudo apk add --no-cache bash sqlite tar gzip findutils coreutils
```

By default, `AUTO_INSTALL_DEPS=0`. The script validates required commands and exits before creating backup files if any are missing, so it does not unexpectedly modify the system.

Optional auto-install on Alpine:

```sh
AUTO_INSTALL_DEPS=1 ./scripts/backup-zeroclaw-to-share.sh
```

Automatic installation is Alpine-only. The script checks for `/etc/alpine-release` or `apk`, uses `apk add --no-cache bash sqlite tar gzip findutils coreutils`, and uses `sudo` when it is not running as root. It does not attempt `apt`, `yum`, `dnf`, or systemd-based setup.

For no-mount SMB upload mode, install `smbclient`:

```sh
sudo apk add --no-cache samba-client
```

If `DEST_MODE=smbclient` and `AUTO_INSTALL_DEPS=1`, the script attempts to install `samba-client` on Alpine when `smbclient` is missing.

## TrueNAS NFS Setup

NFS is recommended for Linux-to-TrueNAS backups.

On TrueNAS, create a dataset such as:

```text
tank/backups/zeroclaw
```

Create an NFS share/export path:

```text
/mnt/tank/backups/zeroclaw
```

Enable and start the NFS service on TrueNAS, then run the setup wizard from the ZeroClaw host:

```sh
./scripts/backup-zeroclaw-to-share.sh --setup-truenas
```

Or use the wrapper:

```sh
./scripts/setup-zeroclaw-truenas-backup.sh
```

Example manual mount:

```sh
sudo apk add --no-cache nfs-utils
sudo mkdir -p /mnt/truenas
sudo mount -t nfs TRUE_NAS_IP:/mnt/tank/backups/zeroclaw /mnt/truenas
```

Optional `/etc/fstab` line:

```fstab
TRUE_NAS_IP:/mnt/tank/backups/zeroclaw /mnt/truenas nfs defaults,_netdev,nofail 0 0
```

The wizard shows the proposed fstab line and asks for confirmation before editing `/etc/fstab`. It creates a timestamped backup such as `/etc/fstab.bak.YYYYMMDD_HHMMSS` before appending a new line.

## TrueNAS SMB Setup

Use SMB/CIFS if you already have a TrueNAS SMB share and user.

On TrueNAS, create an SMB share, for example:

```text
zeroclaw-backups
```

Create or choose a TrueNAS user with access to that share. The setup wizard stores SMB credentials in:

```text
/etc/smbcredentials/truenas-zeroclaw
```

The credentials file is created with mode `600`. SMB passwords are not printed, logged, stored in `~/.zeroclaw-backup.env`, or embedded in generated mount commands.

Example manual credentials file:

```sh
sudo mkdir -p /etc/smbcredentials
sudo sh -c 'umask 077 && printf "username=YOUR_USER\npassword=YOUR_PASSWORD\n" > /etc/smbcredentials/truenas-zeroclaw'
sudo chmod 600 /etc/smbcredentials/truenas-zeroclaw
```

Example manual mount:

```sh
sudo apk add --no-cache cifs-utils
sudo mkdir -p /mnt/truenas
sudo mount -t cifs //TRUE_NAS_IP/zeroclaw-backups /mnt/truenas \
  -o credentials=/etc/smbcredentials/truenas-zeroclaw,vers=3.0,uid=admin,gid=admin,file_mode=0600,dir_mode=0700
```

Optional `/etc/fstab` line:

```fstab
//TRUE_NAS_IP/zeroclaw-backups /mnt/truenas cifs credentials=/etc/smbcredentials/truenas-zeroclaw,vers=3.0,uid=admin,gid=admin,file_mode=0600,dir_mode=0700,_netdev,nofail 0 0
```

## No-Mount SMB Upload Mode

Some constrained Alpine or Proxmox LXC/container-like ZeroClaw hosts cannot perform NFS or CIFS mounts even with `sudo`. A common sign is an empty effective capability set, such as:

```text
CapEff=0000000000000000
```

In those environments, `mount.nfs` or `mount.cifs` may fail with `Operation not permitted`. Use `DEST_MODE=smbclient` to build the backup locally under `/tmp` and upload the completed artifacts to TrueNAS SMB without mounting a filesystem.

Required Alpine package:

```sh
sudo apk add --no-cache samba-client
```

Prepare a credentials file:

```text
/etc/smbcredentials/truenas-zeroclaw
```

The file should contain the SMB username and password:

```text
username=zeroclawbackup
password=REDACTED
```

Keep it readable only by the backup user or by root, depending on how the backup is run. Do not put the SMB password directly in shell commands or cron.

Example upload-only backup:

```sh
DEST_MODE=smbclient \
SMB_URL=//172.16.172.27/zeroclaw-backups \
SMB_USER=zeroclawbackup \
SMB_CREDENTIALS=/etc/smbcredentials/truenas-zeroclaw \
./scripts/backup-zeroclaw-to-share.sh
```

Equivalent CLI flag:

```sh
SMB_URL=//172.16.172.27/zeroclaw-backups \
SMB_USER=zeroclawbackup \
SMB_CREDENTIALS=/etc/smbcredentials/truenas-zeroclaw \
./scripts/backup-zeroclaw-to-share.sh --smbclient-upload
```

In this mode, `SHARE_MOUNT` and `REQUIRE_MOUNT` are not required. The script creates the backup locally first, for example:

```text
/tmp/zeroclaw-backup.${HOST}.${TIMESTAMP}
```

It uploads files to:

```text
${SMB_URL}/${HOST}/${TIMESTAMP}
```

The script uses `smbclient` to create the remote host and timestamp directories, upload each artifact, and list the remote timestamp directory after upload. It deletes the local temporary backup only after every upload succeeds and the remote listing succeeds. If upload fails, the local temporary backup is left in place and the script prints its path.

## Running Backups

For TrueNAS examples, use:

```sh
DEST_ROOT=/mnt/truenas/zeroclaw-backups SHARE_MOUNT=/mnt/truenas REQUIRE_MOUNT=1 ./scripts/backup-zeroclaw-to-share.sh
```

The setup wizard can write non-secret backup settings to:

```text
~/.zeroclaw-backup.env
```

Example generated env file:

```sh
DEST_ROOT=/mnt/truenas/zeroclaw-backups
SHARE_MOUNT=/mnt/truenas
REQUIRE_MOUNT=1
RETENTION_DAYS=30
```

When this file exists, the backup script loads it unless explicit environment variables are already set. The env file never stores SMB passwords.

With the env file in place:

```sh
./scripts/backup-zeroclaw-to-share.sh
```

The env file can also hold non-secret no-mount SMB settings:

```sh
DEST_MODE=smbclient
SMB_URL=//172.16.172.27/zeroclaw-backups
SMB_USER=zeroclawbackup
SMB_CREDENTIALS=/etc/smbcredentials/truenas-zeroclaw
```

Do not store SMB passwords in this env file.

To preview actions without writing backup files:

```sh
DRY_RUN=1 DEST_ROOT=/mnt/truenas/zeroclaw-backups SHARE_MOUNT=/mnt/truenas ./scripts/backup-zeroclaw-to-share.sh
```

## Cron

Example cron entry using the env file:

```cron
30 2 * * * /home/admin/path-to-repo/scripts/backup-zeroclaw-to-share.sh >> /home/admin/zeroclaw-backup.log 2>&1
```

Example cron entry without the env file:

```cron
30 2 * * * DEST_ROOT=/mnt/truenas/zeroclaw-backups SHARE_MOUNT=/mnt/truenas REQUIRE_MOUNT=1 /home/admin/path-to-repo/scripts/backup-zeroclaw-to-share.sh >> /home/admin/zeroclaw-backup.log 2>&1
```

## Restore

Stop ZeroClaw before restoring files into `/home/admin/.zeroclaw`. Do not restore the full tarball over a running ZeroClaw process.

To restore the full `.zeroclaw` directory, move the existing directory aside first, then extract `zeroclaw-full.tar.gz` from a trusted backup.

To restore the SQLite database, prefer `brain.db.backup`. Stop ZeroClaw, place the restored database back at the expected database path, then start ZeroClaw again.

Use `brain.sql` as a human-readable recovery fallback:

```sh
sqlite3 restored-brain.db < brain.sql
```

Validate the restored database:

```sh
sqlite3 restored-brain.db 'PRAGMA integrity_check;'
```

The expected output is:

```text
ok
```

## Troubleshooting

`SHARE_MOUNT is not mounted`: Mount the share first, confirm it appears in `/proc/mounts`, and make sure `SHARE_MOUNT` matches the mounted path exactly. With `REQUIRE_MOUNT=1`, the backup script refuses to write to an unmounted share so it does not accidentally back up into an empty local `/mnt` directory.

`Missing required command(s)`: Install the listed commands before running the backup. If `sqlite3` is missing, the script prints `sudo apk add --no-cache sqlite` and the full recommended Alpine package command. On Alpine only, you can rerun with `AUTO_INSTALL_DEPS=1` to let the script install the required backup packages.

`nfs-utils missing`: Install it with `sudo apk add --no-cache nfs-utils`, or let the TrueNAS setup wizard install missing NFS client tools after confirmation.

`cifs-utils missing`: Install it with `sudo apk add --no-cache cifs-utils`, or let the TrueNAS setup wizard install missing SMB client tools after confirmation.

`smbclient missing`: Install it with `sudo apk add --no-cache samba-client`, or run `DEST_MODE=smbclient AUTO_INSTALL_DEPS=1 ./scripts/backup-zeroclaw-to-share.sh` on Alpine.

`NFS mount fails`: Check the TrueNAS IP or hostname, confirm the NFS service is enabled on TrueNAS, verify the export path such as `/mnt/tank/backups/zeroclaw`, and check dataset permissions.

`SMB mount fails`: Check the TrueNAS IP or hostname, SMB share name, username, password, and dataset/share permissions. Re-run the setup wizard to rewrite `/etc/smbcredentials/truenas-zeroclaw` without printing the password.

`mount.nfs` or `mount.cifs` fails with `Operation not permitted`: The host may be a constrained LXC/container environment without mount capabilities. Use `DEST_MODE=smbclient` so the backup is created under `/tmp` and uploaded with `smbclient` instead of mounting NFS or CIFS.

`SMB upload fails`: Check `SMB_URL`, `SMB_USER`, and `SMB_CREDENTIALS`, confirm the credentials file is readable by the backup process, and confirm the TrueNAS SMB user can create directories and upload files to the share. The local temp backup is retained after failed uploads.

`Permission denied`: Run as a user that can read `/home/admin/.zeroclaw` and write to the mounted share. Root is not required for backups unless your filesystem permissions require it. Setup actions such as mounting, writing `/etc/fstab`, and writing `/etc/smbcredentials/truenas-zeroclaw` require root or `sudo`.

`SQLite backup failed integrity check`: Keep the failed backup directory for inspection, check storage health, and retry after confirming the source database is readable. Do not restore from a backup that fails integrity checks.

`ZeroClaw appears to be running`: This is a warning, not a failure. The SQLite `.backup` output is designed for a live database, but the full tarball may capture live file state. For the most conservative full-directory backup, stop ZeroClaw before running the script.

`Another backup appears to be running`: The lock directory `/tmp/zeroclaw-backup.lock` already exists. Check whether another backup process is active before removing a stale lock.
