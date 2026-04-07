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
- APK update automation uses `/etc/periodic/daily/` + `crond` instead of `unattended-upgrades`
- Checkmk integration keeps the same communication/firewall flow, but Alpine installation is manual by default or via a custom `.apk` URL

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
- Optional SSH rate limiting in both SSH and UFW flow
- Root SSH login disable option
- Password SSH disable option only when key material is detected
- Optional Fail2Ban (recommended)
- Optional automatic patching (interactive)
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
- Alpine Linux (VM and LXC-targeted Alpine entry points)

`system_hardening.sh` auto-detects Debian-family/service differences.
`system_hardening_alpine.sh` is the Alpine-specific entry point and includes VM/LXC-aware defaults.

## License

GPL v3 (see `LICENSE`).
