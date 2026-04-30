# LiteLLM Hardening Toolkit

This directory is intended to live at `/opt/litellm-hardening` on the Debian VM.

It provides a rerunnable, fail-closed deployment toolkit that prefers a signed, digest-pinned LiteLLM container deployment and falls back to:

- interim in-place hardening for an existing helper-script or systemd Python install when migration is unsafe right now
- a pinned Python venv deployment only when you explicitly opt into the venv path and provide a fully locked requirements file with hashes

The default posture is private-by-default for a homelab or small internal team:

- LiteLLM binds to `127.0.0.1` by default
- reverse proxying is optional and off by default
- PostgreSQL and Redis are expected to stay on localhost or private/internal network names
- response caching is disabled by default
- spend logs and error logs are disabled by default to reduce sensitive data retention

## What This Toolkit Enforces

- single source of truth in `/etc/litellm-hardening/litellm.env`
- digest-pinned GHCR image references
- `cosign verify` with LiteLLM's published signing key
- `USE_PRISMA_MIGRATE=True`
- `LITELLM_MODE=PRODUCTION`
- localhost/private binding by default
- PostgreSQL and Redis must look internal unless you explicitly override that guard
- `MAX_IMAGE_URL_DOWNLOAD_SIZE_MB=0` by default
- root-only permissions on the runtime env file
- locked-down config and compose file permissions
- no automatic secret rotation
- no automatic overwriting of an existing `LITELLM_SALT_KEY`
- no automatic overwriting of an existing `LITELLM_MASTER_KEY`

## Default Pinned Container

The bundled defaults pin the official LiteLLM GHCR image to:

- image: `ghcr.io/berriai/litellm`
- tag: `v1.83.3-stable.patch.1`
- digest: `sha256:fc9c0cc5cdfd8bb9a47c51e20a56235b56cf55e93f8c1a880e30a5b3b0a2fb67`

The signing key in [cosign.pub](/e:/Projects/hardening_system_ai/opt/litellm-hardening/cosign.pub) is taken from LiteLLM's documented signed-image workflow.

## Files

- [harden-litellm.sh](/e:/Projects/hardening_system_ai/opt/litellm-hardening/harden-litellm.sh): main entry point
- [validate-litellm.sh](/e:/Projects/hardening_system_ai/opt/litellm-hardening/validate-litellm.sh): preflight and runtime validation
- [backup-litellm.sh](/e:/Projects/hardening_system_ai/opt/litellm-hardening/backup-litellm.sh): backup current state before changes
- [upgrade-litellm.sh](/e:/Projects/hardening_system_ai/opt/litellm-hardening/upgrade-litellm.sh): controlled image upgrade
- [rollback-litellm.sh](/e:/Projects/hardening_system_ai/opt/litellm-hardening/rollback-litellm.sh): restore prior state
- [litellm_config.yaml](/e:/Projects/hardening_system_ai/opt/litellm-hardening/litellm_config.yaml): API-first config template
- [compose/litellm.compose.yaml](/e:/Projects/hardening_system_ai/opt/litellm-hardening/compose/litellm.compose.yaml): API-only container deployment
- [compose/litellm-ui.compose.yaml](/e:/Projects/hardening_system_ai/opt/litellm-hardening/compose/litellm-ui.compose.yaml): UI-enabled variant
- [systemd/litellm-compose.service](/e:/Projects/hardening_system_ai/opt/litellm-hardening/systemd/litellm-compose.service): systemd wrapper for compose
- [systemd/litellm-venv.service](/e:/Projects/hardening_system_ai/opt/litellm-hardening/systemd/litellm-venv.service): fallback pinned venv service

## Expected Runtime Paths

- runtime env: `/etc/litellm-hardening/litellm.env`
- toolkit root: `/opt/litellm-hardening`
- backups: `/var/backups/litellm-hardening`
- state and verification stamps: `/var/lib/litellm-hardening`
- LiteLLM writable paths: `/var/lib/litellm`

## Quick Start

1. Copy this directory to `/opt/litellm-hardening` on the VM.
2. Copy `.env.example` to `/etc/litellm-hardening/litellm.env`.
3. Set at minimum:
   - `LITELLM_MASTER_KEY`
   - `DATABASE_URL`
   - provider credentials
4. Leave `LITELLM_SALT_KEY` blank only if the VM has no existing LiteLLM models or encrypted credentials yet.
5. Run:

```bash
sudo /opt/litellm-hardening/harden-litellm.sh
sudo /opt/litellm-hardening/validate-litellm.sh
```

Preview changes first:

```bash
sudo /opt/litellm-hardening/harden-litellm.sh --dry-run
sudo /opt/litellm-hardening/backup-litellm.sh --dry-run
sudo /opt/litellm-hardening/upgrade-litellm.sh --version <tag> --digest <sha256> --dry-run
sudo /opt/litellm-hardening/rollback-litellm.sh --dry-run
```

## Salt Key Safety

- If `LITELLM_SALT_KEY` already exists anywhere the toolkit can discover, it is preserved and written into the runtime env file once.
- If `LITELLM_SALT_KEY` is absent and LiteLLM state already appears to exist in PostgreSQL or config files, deployment aborts.
- If `LITELLM_SALT_KEY` is absent and no LiteLLM state exists yet, the toolkit can generate it once and persist it to the runtime env file.

## Why the LiteLLM salt key is special

LiteLLM uses `LITELLM_SALT_KEY` to encrypt and decrypt stored credentials and related configuration. In plain English: if you plan to store LiteLLM models, credentials, or encrypted config, you want this key in place before those records are added.

That is why this toolkit is intentionally strict:

- if an existing salt key is found, it is preserved exactly
- if no salt key exists yet and LiteLLM state is still empty, the toolkit can generate one once and store it only in `/etc/litellm-hardening/litellm.env`
- if no salt key exists but LiteLLM already appears to have models, credentials, or encrypted config, the toolkit aborts instead of guessing

You should not casually change this key later. Doing so can make previously stored LiteLLM credentials or configuration unreadable.

## Privacy Notes

Treat LiteLLM caches, database rows, and application logs as sensitive unless you have added your own storage encryption and retention controls.

- cached prompts and completions are not assumed to be encrypted by default
- spend-log rows in PostgreSQL are not assumed to be encrypted by default
- reverse proxy access logs are not assumed to be encrypted by default
- Redis contents are not assumed to be encrypted by default

That is why this toolkit keeps caching off by default, disables prompt storage in spend logs, disables spend logs by default, and keeps reverse proxy exposure optional.

## Reverse Proxy Exposure

Reverse proxying is optional.

- `ENABLE_NGINX=false` by default
- if enabled, the bundled Nginx examples only expose the minimum API paths needed
- the bundled Nginx examples allow localhost and RFC1918/ULA clients by default and deny everything else
- LiteLLM itself still binds to localhost unless you explicitly relax that

## Config Notes

- `enforce_user_param: true` is enabled in the default config
- `reject_clientside_metadata_tags` is left commented because support could not be confirmed from the current official LiteLLM config references used for this toolkit
- `MAX_IMAGE_URL_DOWNLOAD_SIZE_MB=0` is set in the env file by default to block remote image URL downloads unless you explicitly need that feature

## Security Checklist

- Keep `/etc/litellm-hardening/litellm.env` at mode `0600` and owned by `root:root`.
- Keep `/opt/litellm-hardening/litellm_config.yaml` and `/opt/litellm-hardening/compose/active.compose.yaml` at mode `0640`.
- Leave `LITELLM_BIND_ADDRESS=127.0.0.1` unless you have a reviewed reason not to.
- Keep `ENABLE_NGINX=false` unless you actually need proxy exposure.
- If you enable Nginx, use private-network allow rules or another access-control layer in front of it.
- Keep `MAX_IMAGE_URL_DOWNLOAD_SIZE_MB=0` unless image URL fetch support is explicitly required.
- Keep `cache: false` unless you have a private Redis and you accept the retention/privacy tradeoff.
- Keep `disable_spend_logs: true`, `disable_end_user_cost_tracking: true`, and `store_prompts_in_spend_logs: false` unless you intentionally need that data.
- Keep `disable_error_logs: true` unless you are actively troubleshooting and understand the exposure risk.
- Keep PostgreSQL and Redis on localhost or private/internal addresses only.
- Preserve the original `LITELLM_SALT_KEY` and never rotate it casually.
- Verify the pinned GHCR image with cosign before every deployment or upgrade.

## Upgrade Checklist

- Run `backup-litellm.sh` before changing any image tag, digest, or Python lockfile.
- Review the target LiteLLM release notes for config-format changes before upgrading.
- Verify the new image with cosign and record the exact tag and digest.
- Use `upgrade-litellm.sh --dry-run` first.
- Confirm the new release still supports the config keys you rely on.
- Confirm `LITELLM_SALT_KEY` and `LITELLM_MASTER_KEY` are unchanged before the cutover.
- If you use the venv path, regenerate and review the fully hashed lock file deliberately instead of doing floating upgrades.
- Keep the previous backup directory until post-upgrade validation is complete.

## Post-Change Validation Checklist

- Run `/opt/litellm-hardening/validate-litellm.sh`.
- Confirm LiteLLM is listening only on the intended local/private bind address and port.
- Confirm PostgreSQL and Redis are still internal-only.
- Confirm the service health endpoint returns success.
- Confirm `USE_PRISMA_MIGRATE=True` and `LITELLM_MODE=PRODUCTION`.
- Confirm `MAX_IMAGE_URL_DOWNLOAD_SIZE_MB=0` unless you intentionally changed it.
- Confirm `disable_spend_logs: true`, `store_prompts_in_spend_logs: false`, and `disable_error_logs: true` if privacy is the priority.
- Confirm the reverse proxy is still disabled, or if enabled, restricted to the intended clients and routes only.
- Confirm env/config permissions are still locked down.
- Confirm the rollback path is still available and the backup directory is intact.

## Python Venv Fallback

The preferred path is the signed container deployment.

The venv path is intentionally gated:

- you must set `ALLOW_VENV_FALLBACK=true`
- you must supply a populated `venv/requirements.lock` with hashes
- the pinned LiteLLM version must be `>= 1.83.0`

The included `venv/generate-lock.sh` helper is there to build the lock file deliberately, not to perform floating live upgrades.
