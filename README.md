# Homelab Hardening and Checkmk Scripts

This repository contains interactive hardening and monitoring setup scripts for Debian/Ubuntu and Alpine homelab servers.

## Scripts

### `system_hardening.sh` (recommended)
Interactive, menu-driven hardening script for Ubuntu and Debian hosts.

Core behavior:
- Safe defaults with explicit prompts for major choices
- Profile-based role selection
- Summary screen before apply
- Config file backups before writes
- Action logging to a timestamped file
- Rerun-friendly package/config behavior
- SSH lockout protections (allow SSH before UFW enable, key checks before disabling password auth)
- Optional Checkmk integration for every profile
- TLS/HTTPS preference prompts where practical, with weaker modes labeled clearly

Usage:
```bash
sudo ./system_hardening.sh
```

### `system_hardening_alpine.sh`
Interactive Alpine Linux hardening script with the same profile-driven flow as the Debian/Ubuntu build, adapted for `apk`, OpenRC-friendly service management, and Alpine package names.

Usage:
```bash
apk add bash
sudo ./system_hardening_alpine.sh
```

Convenience entry points:
- `system_hardening_alpine_vm.sh` presets the Alpine target to `vm`
- `system_hardening_alpine_lxc.sh` presets the Alpine target to `lxc`

Alpine-specific notes:
- The script asks for an Alpine target (`vm` or `lxc`) and changes defaults/warnings accordingly
- LXC defaults are more conservative around UFW, Fail2Ban, AppArmor, Docker nesting, and kernel forwarding
- Alpine LXC installs `tmux` as a standard helper tool for resilient terminal sessions during hardening and follow-up work
- Alpine LXC ZeroClaw install is supported through an optional source build prompt. This creates a dedicated `zeroclaw` runtime user and installs ZeroClaw under `/home/zeroclaw`
- Prebuilt `x86_64-unknown-linux-gnu` ZeroClaw binaries are GNU/glibc builds and are not suitable for Alpine/musl unless upstream provides a musl build. The Alpine path uses source build instead of `install.sh --prebuilt`
- Recommended ZeroClaw runtime paths are `/home/zeroclaw/.zeroclaw` and `/home/zeroclaw/.cargo/bin/zeroclaw`
- After hardening, finish ZeroClaw setup as the runtime user:

  ```sh
  su - zeroclaw
  zeroclaw onboard
  zeroclaw agent
  ```

- APK update automation uses `/etc/periodic/daily/` + `crond` instead of `unattended-upgrades`
- Checkmk integration keeps the same communication/firewall flow, but Alpine installation is manual by default or via a custom `.apk` URL
- Shared wizard/apply behavior should stay mirrored with `system_hardening.sh` unless Alpine package, init, service, or VM/LXC constraints require a distro-specific branch
- Run `python verify_hardening_sync.py` after shared hardening changes to catch accidental drift
- Run `bash test_access_account_creation.sh` after touching dedicated access-account creation logic

## Interactive Menu Flow

1. Environment detection (distro, init system, SSH service, current SSH port)
2. Alpine target selection for the Alpine build (`vm` or `lxc`)
3. Profile selection menu
4. SSH hardening prompts
5. Firewall prompts (UFW defaults + SSH safety + optional extras)
6. Profile-specific prompts
7. Security services prompts (Fail2Ban, AppArmor, update strategy)
8. Optional Checkmk integration (TLS preferred vs legacy plaintext mode)
9. Full summary and warning review
10. Final apply confirmation
11. Apply phase with logging and backups

## Profile Matrix

| Profile | Primary Use | Default Exposure Posture | Encryption/TLS Posture | Notable Interactive Choices |
|---|---|---|---|---|
| `lan-only` | Minimal internal host | SSH only + optional LAN ports | SSH hardened; optional Checkmk TLS | Extra LAN ports |
| `docker-host` | Container host | SSH + optional app ports | Docker API prompt is TLS-only (`2376`) | Install Docker, open TLS Docker API, extra ports |
| `file-server` | Samba/NAS | SSH + optional Samba ports | SMB encryption policy (`required`/`desired`/`off`) | Install Samba, SMB port exposure, SMB encryption mode |
| `media-host` | Media workloads | SSH + optional direct media ports | Direct Plex prompt marked weaker than HTTPS proxying | Expose Plex `32400`, extra media ports |
| `public-reverse-proxy` | Internet-facing reverse proxy | HTTPS-only preferred, optional HTTP+HTTPS | HTTPS-first publishing, optional Certbot flow | Install Nginx/Certbot, web exposure mode, cert issuance |
| `tailscale-gateway` | Identity-aware private gateway | SSH can be restricted to `tailscale0` | Tailscale SSH prompt (encrypted admin path), forwarding options | Tailscale install, SSH restriction, subnet routing, `tailscale up` |
| `custom` | Build-your-own role | User-defined | User-defined with same global safety checks | Custom firewall ports and package list |

### Docker-Host Package Behavior

On Debian/Ubuntu, the `docker-host` profile installs APT prerequisites first, then prefers the official Docker APT repository when the detected OS and codename support it. The repository is written idempotently under `/etc/apt/sources.list.d/` and uses a GPG key in `/etc/apt/keyrings`, not `apt-key`.

Docker Compose v2 is checked before install. The script installs `docker-compose-plugin` when available, falls back to a valid v2 distro package such as `docker-compose-v2` when appropriate, and does not automatically install the legacy Python `docker-compose` v1 package. If Docker Engine installs but Compose v2 is unavailable, the run reports a controlled warning with `apt-cache policy docker-compose-plugin docker-compose-v2` remediation steps.

## Checkmk Integration (All Profiles)

The hardening script includes an optional Checkmk stage for every profile.
For `tailscale-gateway`, Checkmk is handled inline in `system_hardening.sh` during the same wizard/apply flow.

Supported paths in `system_hardening.sh`:
- Agent source:
  - `apt` package (`check-mk-agent`)
  - direct `.deb` URL
  - already installed
- Communication mode:
  - `TLS / Agent Controller` (preferred)
  - `Plain TCP 6556` (weaker legacy mode, explicitly labeled)

If plaintext mode is chosen, the script prompts for source IP/CIDR restriction and adds matching UFW rules.

For Alpine:
- Agent source:
  - manual install reminder only (recommended default)
  - custom `.apk` URL (advanced)
  - already installed
- Communication mode remains the same: TLS preferred, plaintext optional with explicit UFW scoping

## Safety Guardrails

- UFW default policy: deny incoming, allow outgoing
- SSH allow rule is added before firewall enable
- Existing and new SSH ports are both allowed when port is changed
- SSH password authentication stays available by default until key login is verified; rerun the hardening script after testing keys to disable passwords
- Debian/Ubuntu SSH keeps `UsePAM yes` for PAM account/session processing while disabling keyboard-interactive auth separately
- Optional SSH rate limiting in both SSH and UFW flow
- Optional QEMU guest agent install for Proxmox/QEMU VMs; skipped for LXC/container targets
- Root SSH login disable option
- Password SSH disable option only when key material is detected
- Optional Fail2Ban (recommended)
- Optional automatic patching (interactive)
- Optional AppArmor (interactive)
- Optional IPv6 disable via a managed sysctl drop-in (`/etc/sysctl.d/99-disable-ipv6.conf`), default off and reversible by removing the drop-in. It can be preselected with `DISABLE_IPV6=true` or `HARDEN_DISABLE_IPV6=true`.
- Summary + final confirmation required before apply

## Logs, Backups, and Reruns

- Logs: `/var/log/homelab-hardening/run-<timestamp>.log`
- Backups: `/var/backups/homelab-hardening/<timestamp>/...`
- Managed config writes are backup-first
- Safe to rerun for iterative hardening/tuning

## App Backups And Restores

The repo includes Alpine-first, no-mount app backup tooling for TrueNAS SMB shares:

- `scripts/backup-app-to-share.sh`
- `scripts/restore-app-from-share.sh`
- `scripts/backup-zeroclaw-to-share.sh`
- `scripts/restore-zeroclaw-from-share.sh`
- `scripts/backup-hermes-to-share.sh`

These use `smbclient` directly and do not require CIFS/NFS mounts, which matters on Alpine or Proxmox LXC-style hosts where mounts can fail with `Operation not permitted` and `CapEff: 0000000000000000`.

ZeroClaw backup example:

```sh
DEST_MODE=smbclient \
SMB_SHARE='//SMB_HOST/zeroclaw-backups' \
SMB_CREDS='/etc/smbcredentials/truenas-zeroclaw' \
SMB_REMOTE_ROOT='zeroclaw-backups' \
./scripts/backup-zeroclaw-to-share.sh
```

Dry run latest restore:

```sh
AUTO_INSTALL_DEPS=1 \
DRY_RUN=1 \
RESTORE_LATEST=1 \
APP_NAME=zeroclaw \
APP_USER=admin \
APP_HOME=/home/admin \
APP_DIR=/home/admin/.zeroclaw \
SMB_SHARE='//SMB_HOST/zeroclaw-backups' \
SMB_CREDS='/etc/smbcredentials/truenas-zeroclaw' \
SMB_REMOTE_ROOT='zeroclaw-backups' \
./scripts/restore-app-from-share.sh
```

Restore a specific timestamp:

```sh
AUTO_INSTALL_DEPS=1 \
RESTORE_CONFIRM=1 \
BACKUP_HOST=alpine-claw3 \
BACKUP_TIMESTAMP=20260427_022240 \
APP_NAME=zeroclaw \
APP_USER=admin \
APP_HOME=/home/admin \
APP_DIR=/home/admin/.zeroclaw \
SMB_SHARE='//SMB_HOST/zeroclaw-backups' \
SMB_CREDS='/etc/smbcredentials/truenas-zeroclaw' \
SMB_REMOTE_ROOT='zeroclaw-backups' \
./scripts/restore-app-from-share.sh
```

Backups may contain API keys, tokens, Telegram bot tokens, Ollama keys, SMTP secrets, databases, and app configs. Keep the TrueNAS share access-controlled and rotate exposed secrets if credential files or shell history are accidentally backed up.

See `docs/app-backup-to-truenas.md` for the full backup and restore workflow.

## LiteLLM Gateway

This repo includes a hardened, rerunnable LiteLLM Gateway installer for a dedicated Debian/Ubuntu VM. The gateway is intended for LAN/Tailscale-only use in front of OpenRouter first, with local Ollama/vLLM routes added later.

The LiteLLM workflow is Docker-only. It does not install LiteLLM from PyPI, requires cosign verification by default, rejects unsafe image tags such as `latest`, resolves images to immutable `sha256` digests, and generates a private Postgres-backed Compose deployment.

### Which File To Use When

| File | Use When | Runs On |
|---|---|---|
| `scripts/setup-litellm-gateway.sh` | First install or safe rerun of the gateway VM | Target Debian/Ubuntu VM |
| `scripts/verify-litellm-gateway.sh` | Check container health, digest pinning, UFW exposure, `.env` permissions, PyPI absence, and API smoke tests | Target Debian/Ubuntu VM |
| `scripts/configure-ollama-cloud-bridge.sh` | Configure host Ollama as the private bridge used by LiteLLM | Target Debian/Ubuntu VM |
| `scripts/verify-ollama-cloud-bridge.sh` | Verify host Ollama, container reachability, chat, and embeddings through the bridge | Target Debian/Ubuntu VM |
| `scripts/create-litellm-client-key.sh` | Create scoped LiteLLM virtual keys for clients | Target Debian/Ubuntu VM |
| `scripts/update-litellm-gateway.sh` | Move to an explicit new signed LiteLLM image tag and roll back on failed verification | Target Debian/Ubuntu VM |
| `scripts/backup-litellm-gateway.sh` | Back up Compose, config, secrets, and Postgres dump, with optional `smbclient` upload | Target Debian/Ubuntu VM |
| `examples/litellm-gateway.env.example` | See expected environment variables and placeholder-only secret names | Reference only |
| `examples/litellm-gateway.gateway.env.example` | See non-secret network settings saved to `/opt/litellm-gateway/gateway.env` | Reference only |
| `examples/litellm-config.yaml.example` | See the Ollama bridge model config shape | Reference only |
| `docs/litellm-gateway-hardening.md` | Full runbook: rationale, rotation, virtual keys, firewall notes, emergency response | Anywhere |
| `docs/zeroclaw-litellm-integration.md` | Generic ZeroClaw/OpenAI-compatible client setup through LiteLLM | Anywhere |

### Clean VM Quickstart

Use Debian 12/13 or Ubuntu 24.04. Run setup from the repo checkout on the VM:

```sh
sudo ./scripts/setup-litellm-gateway.sh \
  --litellm-host-ip <LITELLM_HOST_IP> \
  --litellm-port <LITELLM_PORT> \
  --trusted-client-cidr <TRUSTED_CLIENT_CIDR> \
  --ollama-bridge-api-base <OLLAMA_BRIDGE_API_BASE> \
  --docker-litellm-subnet <DOCKER_LITELLM_SUBNET>
```

The installer prompts for missing network values and for an optional `OPENROUTER_API_KEY`. Leave OpenRouter blank unless you intentionally want the `openrouter-auto` route.

After setup:

```sh
sudo /opt/litellm-gateway/verify-litellm-gateway.sh
sudo /opt/litellm-gateway/configure-ollama-cloud-bridge.sh
sudo /opt/litellm-gateway/verify-ollama-cloud-bridge.sh
sudo docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml ps
sudo ufw status verbose
```

Point clients at:

```yaml
base_url: http://<LITELLM_HOST_IP>:<LITELLM_PORT>/v1
model: ollama-kimi-k26-cloud
api_key: <LiteLLM virtual key>
```

Update with an explicit stable image tag:

```sh
sudo /opt/litellm-gateway/update-litellm-gateway.sh \
  --image ghcr.io/berriai/litellm-non_root:v1.83.3-stable.patch.2
```

Back up locally:

```sh
sudo /opt/litellm-gateway/backup-litellm-gateway.sh
```

## Validation

- Run `python verify_hardening_sync.py` after shared Debian/Alpine changes to catch drift between the two scripts.
- Run `bash test_ssh_port_detection.sh` after touching SSH detection or validation logic.
- Run `bash test_ipv6_disable.sh` after touching IPv6 sysctl hardening logic.
- Run `bash mock_e2e_tests.sh` for a lightweight repo-level smoke check. It writes local artifacts to ignored `test-run-<timestamp>/` directories.
- Track real cloud test work in `TODO_CLOUD_E2E.md`. Generated cloud or mock run artifacts should stay local and uncommitted.

## Other Scripts

### `checkmk_setup.sh`
Standalone Checkmk agent setup workflow for systems where you only want monitoring bootstrap.
It is not required for `tailscale-gateway` when using `system_hardening.sh`, because that profile configures Checkmk inline.

### `declawer_v1.0.sh`
Legacy hardening script retained for reference.

### `setup_v1.5.sh` / `setup.sh`
Burn-in and host setup scripts retained for specific workflows.

## Compatibility

- Debian (current supported releases)
- Ubuntu (current supported releases)
- Alpine Linux (VM and LXC-targeted Alpine entry points)

`system_hardening.sh` auto-detects Debian-family/service differences.
`system_hardening_alpine.sh` is the Alpine-specific entry point and includes VM/LXC-aware defaults.

## License

GPL v3 (see `LICENSE`).
