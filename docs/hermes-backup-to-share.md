# Hermes Backup To TrueNAS

Hermes backups use the generic app backup engine:

```text
scripts/backup-app-to-share.sh
```

The Hermes wrapper sets app defaults and then calls the engine:

```text
scripts/backup-hermes-to-share.sh
```

For the full generic reference, see `docs/app-backup-to-truenas.md`.

## Recommended Alpine/LXC Mode

Use the default no-mount SMB mode:

```sh
DEST_MODE=smbclient
```

This avoids kernel NFS/CIFS mounts, which can fail on constrained Alpine, Proxmox LXC, or container-style hosts:

```text
mount.nfs: Operation not permitted
mount.cifs: Operation not permitted
CapEff: 0000000000000000
```

## Defaults

The wrapper sets:

```sh
APP_NAME=hermes
APP_USER=admin
APP_HOME=/home/admin
APP_DIR=/home/admin/hermes
```

If `APP_DIR` is not set, the wrapper chooses the first existing directory from:

- `/home/admin/hermes`
- `/home/admin/.hermes`
- `/opt/hermes`
- `/srv/hermes`

Likely config files are copied when present:

- `.env`
- `config.toml`
- `config.yaml`
- `config.yml`
- `settings.toml`
- `settings.yaml`
- `docker-compose.yml`

The generic engine searches for any `*.db`, `*.sqlite`, or `*.sqlite3` files under the Hermes app directory. Hermes does not need to have SQLite; if no database exists, the backup continues with the tarball and config files.

Version detection is best effort:

- `hermes --version` if available
- `git rev-parse HEAD` when `APP_DIR` is a git repo
- `unknown` otherwise

## TrueNAS SMB Example

Create a TrueNAS SMB dataset/share such as:

```text
zeroclaw-backups
```

Create a backup user with write access, enable SMB service, and enable Samba authentication for that user.

Create a credentials file:

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

Run a Hermes backup:

```sh
DEST_MODE=smbclient \
APP_DIR=/home/admin/hermes \
SMB_SHARE='//172.16.172.27/zeroclaw-backups' \
SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' \
./scripts/backup-hermes-to-share.sh
```

Remote layout:

```text
${SMB_REMOTE_ROOT}/hermes/${HOST}/${TIMESTAMP}/
```

## Artifacts

The backup contains:

- `manifest.txt`
- `hermes-full.tar.gz`
- `configs/` for config files that exist
- `sqlite/*.backup` and `sqlite/*.sql` when databases are found
- `sqlite_integrity_check.txt`
- `SHA256SUMS.txt`

## Dry Run

```sh
DRY_RUN=1 \
DEST_MODE=smbclient \
APP_DIR=/home/admin/hermes \
SMB_SHARE='//172.16.172.27/zeroclaw-backups' \
SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' \
./scripts/backup-hermes-to-share.sh
```

## Mounted Mode

Mounted mode remains available for normal hosts:

```sh
DEST_MODE=mounted \
APP_DIR=/home/admin/hermes \
DEST_ROOT=/mnt/truenas \
SHARE_MOUNT=/mnt/truenas \
REQUIRE_MOUNT=1 \
./scripts/backup-hermes-to-share.sh
```

The mounted path is:

```text
${DEST_ROOT}/hermes/${HOST}/${TIMESTAMP}/
```

## Cron

```cron
45 2 * * * DEST_MODE=smbclient APP_DIR=/home/admin/hermes SMB_SHARE='//172.16.172.27/zeroclaw-backups' SMB_CREDS='/home/admin/.smbcredentials/truenas-zeroclaw' /home/admin/hardening_system_ai/scripts/backup-hermes-to-share.sh >> /home/admin/hermes-backup.log 2>&1
```

## Restore

Stop Hermes before restoring.

Verify the backup:

```sh
sha256sum -c SHA256SUMS.txt
```

Restore the app directory by moving the current Hermes directory aside, then extracting `hermes-full.tar.gz`.

Restore SQLite databases from `sqlite/*.backup` files when present. Use `.sql` files as readable fallbacks:

```sh
sqlite3 restored-hermes.db < sqlite/001-hermes.db.sql
sqlite3 restored-hermes.db 'PRAGMA integrity_check;'
```

Expected output:

```text
ok
```

## Security

Hermes backups may contain API keys, tokens, Telegram bot tokens, Ollama keys, SMTP secrets, environment files, and app configs. Protect the TrueNAS share as sensitive storage.

If shell history, credential files, or secrets are accidentally uploaded, rotate the affected passwords and tokens.

## Troubleshooting

`APP_DIR does not exist`: Set `APP_DIR` to the actual Hermes directory.

`mount.nfs` or `mount.cifs` fails with `Operation not permitted`: Use `DEST_MODE=smbclient`. If `grep CapEff /proc/self/status` shows `CapEff: 0000000000000000`, the process has no effective Linux capabilities.

`SMB credentials file is not readable`: Copy it into the backup user's home with:

```sh
sudo install -o admin -g admin -m 600 /etc/smbcredentials/truenas-zeroclaw /home/admin/.smbcredentials/truenas-zeroclaw
```

`SMB upload fails`: Check `SMB_SHARE`, `SMB_CREDS`, optional `SMB_REMOTE_ROOT`, and TrueNAS permissions. The local staging directory remains in `/tmp` after failures.

The SMB uploader never uses `mput *` or wildcard uploads.
