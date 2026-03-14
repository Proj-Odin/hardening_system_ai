# Homelab Hardening and Checkmk Scripts

This repository contains interactive hardening and monitoring setup scripts for Debian/Ubuntu homelab servers.

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

## Interactive Menu Flow

1. Environment detection (Ubuntu/Debian, SSH service, current SSH port)
2. Profile selection menu
3. SSH hardening prompts
4. Firewall prompts (UFW defaults + SSH safety + optional extras)
5. Profile-specific prompts
6. Security services prompts (Fail2Ban, AppArmor, update strategy)
7. Optional Checkmk integration (TLS preferred vs legacy plaintext mode)
8. Full summary and warning review
9. Final apply confirmation
10. Apply phase with logging and backups

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

## Checkmk Integration (All Profiles)

The hardening script includes an optional Checkmk stage for every profile.
For `tailscale-gateway`, Checkmk is handled inline in `system_hardening.sh` during the same wizard/apply flow.

Supported paths:
- Agent source:
  - `apt` package (`check-mk-agent`)
  - direct `.deb` URL
  - already installed
- Communication mode:
  - `TLS / Agent Controller` (preferred)
  - `Plain TCP 6556` (weaker legacy mode, explicitly labeled)

If plaintext mode is chosen, the script prompts for source IP/CIDR restriction and adds matching UFW rules.

## Safety Guardrails

- UFW default policy: deny incoming, allow outgoing
- SSH allow rule is added before firewall enable
- Existing and new SSH ports are both allowed when port is changed
- Optional SSH rate limiting in both SSH and UFW flow
- Root SSH login disable option
- Password SSH disable option only when key material is detected
- Optional Fail2Ban (recommended)
- Optional unattended-upgrades (interactive)
- Optional AppArmor (interactive)
- Summary + final confirmation required before apply

## Logs, Backups, and Reruns

- Logs: `/var/log/homelab-hardening/run-<timestamp>.log`
- Backups: `/var/backups/homelab-hardening/<timestamp>/...`
- Managed config writes are backup-first
- Safe to rerun for iterative hardening/tuning

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

`system_hardening.sh` auto-detects distro/service differences (for example SSH service naming).

## License

GPL v3 (see `LICENSE`).
