# ZeroClaw Backup To TrueNAS

ZeroClaw backups now use the generic app backup engine:

```text
scripts/backup-app-to-share.sh
```

The ZeroClaw wrapper sets sane defaults and then calls the engine:

```text
scripts/backup-zeroclaw-to-share.sh
```

For the full generic reference, see `docs/app-backup-to-truenas.md`.

## Recommended Alpine/LXC Mode

Use the default no-mount SMB mode:

```sh
DEST_MODE=smbclient
```

This is the safest mode for constrained Alpine, Proxmox LXC, or container-style hosts where mounts can fail:

```text
mount.nfs: Operation not permitted
mount.cifs: Operation not permitted
CapEff: 0000000000000000
```

`smbclient` does not require kernel mount capabilities.

## Defaults

The wrapper sets:

```sh
APP_NAME=zeroclaw
APP_USER=admin
APP_HOME=/home/admin
APP_DIR=/home/admin/.zeroclaw
APP_CONFIG_FILES=/home/admin/.zeroclaw/config.toml
APP_SQLITE_CANDIDATES=/home/admin/.zeroclaw/workspace/memory/brain.db
```

The generic engine also searches for any `*.db`, `*.sqlite`, or `*.sqlite3` files under `APP_DIR`.

Version detection checks:

- `zeroclaw` in `PATH`
- `/home/admin/.cargo/bin/zeroclaw`
- `/home/admin/.local/bin/zeroclaw`

## TrueNAS SMB Example

Create a TrueNAS SMB dataset/share such as:

```text
zeroclaw-backups
```

Create a backup user with write access to the share, enable SMB service, and enable Samba authentication for that user.

Create a credentials file on the Alpine host:

```sh
mkdir -p /home/admin/.smbcredentials
chmod 700 /home/admin/.smbcredentials
cat > /home/admin/.smbcredentials/truenas-zeroclaw <<'EOF'
username=zeroclawbackup
password=REDACTED
EOF
chmod 600 /home/admin/.smbcredentials/truenas-zeroclaw
```

Test access:

```sh
smbclient //172.16.172.27/zeroclaw-backups -A /home/admin/.smbcredentials/truenas-zeroclaw -c 'ls'
```

Run a backup:

```sh
DEST_MODE=smbclient \
SMB_SHARE='//172.16.172.27/zeroclaw-backups' \
SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' \
./scripts/backup-zeroclaw-to-share.sh
```

Remote layout:

```text
${SMB_REMOTE_ROOT}/zeroclaw/${HOST}/${TIMESTAMP}/
```

`SMB_REMOTE_ROOT` is optional. `SMB_HOST_DIR` can override the host folder name.

## Artifacts

The backup contains:

- `manifest.txt`
- `zeroclaw-full.tar.gz`
- `configs/config.toml` when present
- `sqlite/*.backup` for SQLite native backups
- `sqlite/*.sql` for readable SQL dumps
- `sqlite_integrity_check.txt`
- `SHA256SUMS.txt`

If no SQLite database is found, the backup continues and records that in `manifest.txt` and `sqlite_integrity_check.txt`.

## Dry Run

Preview without creating backup files or remote directories:

```sh
DRY_RUN=1 \
DEST_MODE=smbclient \
SMB_SHARE='//172.16.172.27/zeroclaw-backups' \
SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' \
./scripts/backup-zeroclaw-to-share.sh
```

`DRY_RUN=1` does not require a mounted share in `smbclient` mode.

## Mounted Mode

Mounted mode remains available for normal hosts where a share is already mounted:

```sh
DEST_MODE=mounted \
DEST_ROOT=/mnt/truenas \
SHARE_MOUNT=/mnt/truenas \
REQUIRE_MOUNT=1 \
./scripts/backup-zeroclaw-to-share.sh
```

The mounted path is:

```text
${DEST_ROOT}/zeroclaw/${HOST}/${TIMESTAMP}/
```

With `REQUIRE_MOUNT=1`, the script refuses to write unless `SHARE_MOUNT` appears in `/proc/self/mounts`.

## Cron

```cron
30 2 * * * DEST_MODE=smbclient SMB_SHARE='//172.16.172.27/zeroclaw-backups' SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' /home/admin/hardening_system_ai/scripts/backup-zeroclaw-to-share.sh >> /home/admin/zeroclaw-backup.log 2>&1
```

## Restore

Stop ZeroClaw before restoring.

Verify the backup:

```sh
sha256sum -c SHA256SUMS.txt
```

Restore the full `.zeroclaw` directory by moving the current directory aside, then extracting `zeroclaw-full.tar.gz`.

Restore SQLite from the `.backup` files under `sqlite/`. Use `.sql` as a readable fallback:

```sh
sqlite3 restored-brain.db < sqlite/001-brain.db.sql
sqlite3 restored-brain.db 'PRAGMA integrity_check;'
```

Expected output:

```text
ok
```

## Security

ZeroClaw backups may contain API keys, tokens, memory databases, and app config. Protect the TrueNAS share as sensitive storage.

If shell history, credential files, or tokens are accidentally uploaded, rotate the affected passwords and tokens.

## Troubleshooting

`mount.nfs` or `mount.cifs` fails with `Operation not permitted`: Use `DEST_MODE=smbclient`. If `grep CapEff /proc/self/status` shows `CapEff: 0000000000000000`, the process has no effective Linux capabilities.

`SMB credentials file is not readable`: Copy it into the backup user's home with:

```sh
sudo install -o admin -g admin -m 600 /etc/smbcredentials/truenas-zeroclaw /home/admin/.smbcredentials/truenas-zeroclaw
```

`SMB upload fails`: Check `SMB_SHARE`, `SMB_CREDS`, optional `SMB_REMOTE_ROOT`, and TrueNAS permissions. The local staging directory remains in `/tmp` after failures.

The SMB uploader never uses `mput *` or wildcard uploads.
