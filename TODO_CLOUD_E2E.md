# Cloud E2E Backlog for Hardening Scripts

**Project:** Homelab Hardening and Checkmk Scripts
**Target Platforms:** Ubuntu 22.04 LTS and Debian 12
**Status:** Planning backlog only; no cloud run artifacts should be committed to the repo
**Last Updated:** 2026-04-20

## Goals

- exercise `system_hardening.sh` end-to-end on disposable cloud hosts
- verify SSH safety, rerun behavior, and service-specific profile outcomes
- collect enough logs and config state to debug failures without leaving VMs behind
- keep generated cloud artifacts local in ignored `test-run-*` directories

## What Is Already Covered Locally

- `python verify_hardening_sync.py`
  Confirms shared Debian/Alpine function order and approved drift.
- `bash test_ssh_port_detection.sh`
  Covers SSH port autodetection fallback behavior for Debian and Alpine.
- `bash mock_e2e_tests.sh`
  Runs a lightweight repo smoke check and writes ignored local artifacts.

These checks are useful preflight gates, but they do **not** replace real cloud validation of packages, services, firewall state, or SSH reachability after apply.

## Preflight

- [ ] Choose the provider wrapper for the first real run: `doctl`, `hcloud`, `aws`, or `linode-cli`
- [ ] Register an SSH key with the provider and confirm passwordless SSH from the runner
- [ ] Confirm the base image and instance size for Ubuntu 22.04 / Debian 12
- [ ] Confirm the runner has `bash`, `git`, `scp`, `ssh`, and the provider CLI installed
- [ ] Create a fresh ignored artifact root such as `test-run-$(date +%Y%m%d-%H%M%S)`
- [ ] Decide whether the run is single-profile smoke or parallel matrix
- [ ] Write or review a cleanup command path before provisioning anything

## Cloud Test Matrix

| Priority | Scenario | Target | What must be true at the end |
|---|---|---|---|
| P0 | Base LAN-only hardening | `system_hardening.sh` | exit code `0`, SSH still works, UFW active, logs/backups created |
| P0 | Rerun safety | `system_hardening.sh` twice | second run succeeds, no duplicate SSH/UFW state, new backup/log set created |
| P0 | Docker profile | `system_hardening.sh` | Docker installed, service active, SSH preserved |
| P0 | File-server profile | `system_hardening.sh` | Samba installed, expected ports opened, SSH preserved |
| P0 | Tailscale gateway profile | `system_hardening.sh` | Tailscale installed, profile flow completes safely, SSH preserved |
| P0 | SSH password disable safety | `system_hardening.sh` | key auth works, UFW SSH access is present before password auth is disabled |
| P0 | Custom SSH port migration | `system_hardening.sh` | old and new SSH ports are safely handled during transition, new port reachable |
| P1 | Public reverse proxy profile | `system_hardening.sh` | Nginx installed, expected web exposure matches chosen mode, SSH preserved |
| P1 | Checkmk TLS install | `checkmk_setup.sh` | agent installs cleanly, expected TLS assets exist, SSH preserved |
| P1 | Checkmk plaintext with CIDR restriction | `checkmk_setup.sh` | `6556/tcp` is restricted as intended, SSH preserved |
| P1 | Fail2Ban integration | `system_hardening.sh` | Fail2Ban active, sshd jail available, SSH preserved |
| P1 | Backup and restore validation | `system_hardening.sh` | SSH/UFW backups exist at expected paths and can support manual recovery |

## Suggested Cloud Workflow

1. Provision a disposable VM.
   Use a provider CLI or IaC wrapper that returns a VM identifier and public IP.
2. Wait for SSH readiness before copying anything.
   Verify a baseline `ssh root@<ip> "echo ready"` succeeds first.
3. Copy the repo to the VM.
   Use `scp -r` or an equivalent archive transfer to `/opt/hardening_system_ai`.
4. Run local preflight on the runner.
   Execute `python verify_hardening_sync.py`, `bash test_ssh_port_detection.sh`, and `bash mock_e2e_tests.sh`.
5. Execute the selected profile on the VM.
   Prefer a checked-in, re-recorded stdin transcript once the current prompt flow is frozen.
6. Validate post-apply state immediately.
   Check SSH reachability, service status, firewall rules, and timestamped logs/backups.
7. Collect artifacts back to the runner.
   Pull `/var/log/homelab-hardening/`, relevant configs, and UFW/service snapshots into the ignored `test-run-*` directory.
8. Destroy the VM.
   Cleanup is required even for failed runs.

## Artifact Conventions

- Use a unique root such as `test-run-20260420-153000/`
- Recommended subdirectories:
  - `logs/`
  - `configs/`
  - `ufw-rules/`
  - `services/`
  - `notes/`
- Recommended metadata files:
  - `vm-inventory.txt`
  - `results.txt`
  - `summary.md`

## Immediate Next Tasks

### P0

- [ ] Record fresh stdin transcripts for the current wizard flow instead of relying on March notes
- [ ] Add one provider-specific provisioning wrapper for the first supported cloud platform
- [ ] Add a profile runner that executes a selected transcript and captures the remote exit code
- [ ] Add SSH post-checks for both the default port and custom-port migration cases
- [ ] Add artifact collection commands for logs, configs, UFW rules, and service status

### P1

- [ ] Add matrix support for running multiple profiles in parallel
- [ ] Add a cleanup helper that destroys every VM listed in `vm-inventory.txt`
- [ ] Add a summarized markdown report generated from `results.txt`
- [ ] Add explicit Checkmk TLS and plaintext validation helpers
- [ ] Add restore drill notes for SSH and UFW backups

## Success Criteria

- All P0 scenarios pass with exit code `0`
- No SSH lockout events occur during or after apply
- Rerun behavior stays idempotent for firewall and backup/log creation
- Cloud artifacts are captured locally but remain untracked by git
- Every provisioned VM is destroyed before the run is considered complete
