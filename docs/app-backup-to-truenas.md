# App Backup To TrueNAS

## Recommended Mode

`scripts/backup-app-to-share.sh` is an Alpine-first backup engine for app directories that should be copied to a TrueNAS SMB share without requiring kernel mounts.

The default mode is:

```sh
DEST_MODE=smbclient
```

This is recommended for Alpine, Proxmox LXC, and container-style hosts because NFS/CIFS mounts may fail even with `sudo`:

```text
mount.nfs: Operation not permitted
mount.cifs: Operation not permitted
CapEff: 0000000000000000
```

`smbclient` uploads over SMB without requiring mount capabilities. Mounted-share backups remain available with `DEST_MODE=mounted` for normal hosts where a share is already mounted.

## What Gets Created

Every run creates a secure local staging directory first:

```text
/tmp/${APP_NAME}-backup-${HOST}-${TIMESTAMP}.XXXXXX
```

Artifacts:

- `manifest.txt`
- `${APP_NAME}-full.tar.gz`
- `configs/` for configured config files that exist
- `sqlite/` for SQLite `.backup` and `.sql` files when databases are found
- `sqlite_integrity_check.txt`
- `SHA256SUMS.txt`

When `APP_EXTRA_PATHS` is set, the engine also creates `${APP_NAME}-extra-paths.tar.gz` and `extra-paths.txt`.

SQLite databases are backed up with `sqlite3 ".backup"`, dumped to readable SQL, and checked with `PRAGMA integrity_check;`. If a discovered database fails integrity check, the backup fails.

## TrueNAS SMB Setup

On TrueNAS:

1. Create a dataset and SMB share, for example `zeroclaw-backups`.
2. Enable the SMB service.
3. Create or choose a backup user with write access to the share.
4. Enable Samba authentication for that user.

On the Alpine host, install the no-mount backup tools:

```sh
sudo apk add --no-cache bash sqlite samba-client tar gzip findutils coreutils
```

Create a credentials file readable by the backup user:

```sh
mkdir -p /home/admin/.smbcredentials
chmod 700 /home/admin/.smbcredentials
cat > /home/admin/.smbcredentials/truenas-zeroclaw <<'EOF'
username=zeroclawbackup
password=REDACTED
EOF
chmod 600 /home/admin/.smbcredentials/truenas-zeroclaw
```

Do not put SMB passwords directly in commands, cron, or generated env files.

Test SMB access:

```sh
smbclient //SMB_HOST/zeroclaw-backups -A /home/admin/.smbcredentials/truenas-zeroclaw -c 'ls'
```

If the script says the credentials file is not readable, copy a root-owned credential into the user-readable path:

```sh
sudo install -o admin -g admin -m 600 /etc/smbcredentials/truenas-zeroclaw /home/admin/.smbcredentials/truenas-zeroclaw
```

## Generic Usage

Minimum no-mount SMB run:

```sh
APP_NAME=myapp \
APP_USER=admin \
APP_HOME=/home/admin \
APP_DIR=/home/admin/myapp \
SMB_SHARE='//SMB_HOST/zeroclaw-backups' \
SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' \
./scripts/backup-app-to-share.sh
```

Remote layout:

```text
${SMB_REMOTE_ROOT}/${APP_NAME}/${HOST}/${TIMESTAMP}/
```

`SMB_REMOTE_ROOT` is optional. `SMB_HOST_DIR` defaults to `hostname -s` and can be set when you want a stable host folder name.

Dry run:

```sh
DRY_RUN=1 \
APP_NAME=myapp \
APP_DIR=/home/admin/myapp \
SMB_SHARE='//SMB_HOST/zeroclaw-backups' \
SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' \
./scripts/backup-app-to-share.sh
```

`DRY_RUN=1` does not create local backup files or remote SMB directories. In `DEST_MODE=smbclient`, it does not require `SHARE_MOUNT` to be mounted.

## App Variables

Common variables:

```sh
APP_NAME=myapp
APP_USER=admin
APP_HOME=/home/admin
APP_DIR=/home/admin/myapp
APP_CONFIG_FILES="/home/admin/myapp/.env
/home/admin/myapp/config.toml"
APP_SQLITE_CANDIDATES="/home/admin/myapp/data/app.db"
APP_EXTRA_PATHS=""
DEST_MODE=smbclient
RETENTION_DAYS=30
CLEAN_LOCAL_AFTER_UPLOAD=0
AUTO_INSTALL_DEPS=0
```

SMB mode:

```sh
SMB_SHARE='//SMB_HOST/zeroclaw-backups'
SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw'
SMB_REMOTE_ROOT=''
SMB_HOST_DIR=''
```

Mounted mode:

```sh
DEST_MODE=mounted
DEST_ROOT=/mnt/truenas
SHARE_MOUNT=/mnt/truenas
REQUIRE_MOUNT=1
```

With `REQUIRE_MOUNT=1`, mounted mode refuses to write unless `SHARE_MOUNT` is actually mounted. Mount detection reads `/proc/self/mounts` and handles escaped spaces such as `\040`.

## Upload Safety

The SMB uploader never uses `mput *` or wildcard upload commands. It uploads only the artifact list generated inside the secure staging directory:

- root files such as `manifest.txt`, `SHA256SUMS.txt`, and `${APP_NAME}-full.tar.gz`
- files under `configs/`
- files under `sqlite/`
- optional extra-path tarball files

If SMB upload or validation fails, the local staging directory stays in `/tmp` and the script prints its path. The staging directory is deleted only when `CLEAN_LOCAL_AFTER_UPLOAD=1` and upload validation succeeds.

## AUTO_INSTALL_DEPS

`AUTO_INSTALL_DEPS=0` is the default. The script prints the missing commands and an Alpine `apk add` command.

With `AUTO_INSTALL_DEPS=1`, the script installs missing packages on Alpine only:

```sh
AUTO_INSTALL_DEPS=1 ./scripts/backup-zeroclaw-to-share.sh
```

It uses `sudo` when not running as root and `sudo` exists. It does not attempt `apt`, `dnf`, or `yum`.

## Cron

ZeroClaw:

```cron
30 2 * * * DEST_MODE=smbclient SMB_SHARE='//SMB_HOST/zeroclaw-backups' SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' /home/admin/hardening_system_ai/scripts/backup-zeroclaw-to-share.sh >> /home/admin/zeroclaw-backup.log 2>&1
```

Hermes:

```cron
45 2 * * * DEST_MODE=smbclient APP_DIR=/home/admin/hermes SMB_SHARE='//SMB_HOST/zeroclaw-backups' SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' /home/admin/hardening_system_ai/scripts/backup-hermes-to-share.sh >> /home/admin/hermes-backup.log 2>&1
```

## Restore

Stop the app before restoring files.

Download or open a timestamped backup directory, then verify checksums:

```sh
sha256sum -c SHA256SUMS.txt
```

Restore the full app directory by moving the existing directory aside, then extracting `${APP_NAME}-full.tar.gz` from a trusted backup.

Restore SQLite databases from `sqlite/*.backup` files when available. Use matching `sqlite/*.sql` files as readable recovery fallbacks:

```sh
sqlite3 restored.db < sqlite/001-app.db.sql
sqlite3 restored.db 'PRAGMA integrity_check;'
```

The expected integrity output is:

```text
ok
```

## Security

Backups may contain API keys, tokens, Telegram bot tokens, Ollama keys, SMTP secrets, databases, and app configs. The TrueNAS share must be access-controlled.

If shell history, credential files, or secrets are accidentally uploaded, rotate the affected passwords and tokens.

## Troubleshooting

`mount.nfs` or `mount.cifs` fails with `Operation not permitted`: Use `DEST_MODE=smbclient`. Check `grep CapEff /proc/self/status`; `CapEff: 0000000000000000` means the process has no effective Linux capabilities.

`smbclient missing`: Install `sudo apk add --no-cache samba-client`, or rerun on Alpine with `AUTO_INSTALL_DEPS=1`.

`SMB upload fails`: Check `SMB_SHARE`, `SMB_CREDS`, and optional `SMB_REMOTE_ROOT`. Confirm the SMB user can create directories and upload files. The local staging directory is retained after failures.

`SHARE_MOUNT is not mounted`: This only applies to `DEST_MODE=mounted`. Mount the share first, or use the default `DEST_MODE=smbclient`.
