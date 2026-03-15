# Cloud E2E Testing TODO for Hardening System

**Project:** Homelab Hardening and Checkmk Scripts
**Target Platform:** Ubuntu 22.04 LTS / Debian 12
**Testing Approach:** Scripted, non-interactive cloud VM provisioning with automated input injection
**Last Updated:** 2026-03-15

---

## Overview

This TODO tracks end-to-end integration tests for `system_hardening.sh`, `checkmk_setup.sh`, and profile-specific hardening flows. Tests run on ephemeral cloud VMs with exact commands for reproduction. Each test includes rollback/safety steps to preserve SSH access and prevent lockout scenarios.

---

## Test Infrastructure Setup

### P0: VM Provisioning Template

**Task:** Create reusable cloud VM provisioning script
- **Acceptance Criteria:**
  - Provisions Ubuntu 22.04 LTS or Debian 12 VM on cloud provider (DigitalOcean/Hetzner/AWS/Linode)
  - VM has SSH access, sudo, `curl`, `bash`, and `git` pre-installed
  - Timestamps and VM IDs in artifact directories for unique runs
  - Can provision 4-6 VMs in parallel for profile matrix testing
  - Includes cleanup/destroy targets

- **Exact Commands:**
  ```bash
  # Cloud CLI example (DigitalOcean)
  doctl compute droplet create \
    --image ubuntu-22-04-x64 \
    --region sfo3 \
    --size s-1vcpu-512mb-10gb \
    --ssh-keys <key-id> \
    --wait \
    --no-header \
    --format ID,PublicIPv4 \
    hardening-test-${PROFILE}-${RUN_ID}

  # Capture IP and add to inventory
  VM_IP=$(doctl compute droplet get hardening-test-${PROFILE}-${RUN_ID} --format PublicIPv4 --no-header)

  # Wait for SSH readiness
  for i in {1..30}; do
    ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no root@${VM_IP} "echo ready" && break || sleep 10
  done
  ```

- **Expected Artifacts:**
  - `test-run-${TIMESTAMP}/vm-inventory.txt` (IP, VM ID, hostname)
  - `test-run-${TIMESTAMP}/provision.log`
  - VM lifecycle state for cleanup

---

## Core Hardening Functionality Tests

### P0: Basic Hardening Flow (LAN-Only Profile)

**Task:** Verify `system_hardening.sh` core flow end-to-end
- **Profile:** `lan-only`
- **Input Selections:** Default minimal hardening
- **Acceptance Criteria:**
  - Script completes without errors (exit code 0)
  - SSH remains accessible post-hardening (test SSH login after completion)
  - UFW is enabled with SSH allow rule in place
  - Logs created in `/var/log/homelab-hardening/run-*.log`
  - Backups archived in `/var/backups/homelab-hardening/`
  - No unintended service restarts lose SSH connection

- **Exact Commands:**
  ```bash
  VM_IP="<provision_output>"
  RUN_ID="$(date +%s)"

  # Prepare input script for non-interactive mode
  cat > /tmp/input-lan.txt <<'EOF'
  1
  1
  n
  y
  y
  y
  n
  n
  y
  y
  EOF

  # Copy repo and input to VM
  scp -r /path/to/hardening_system_ai root@${VM_IP}:/opt/
  scp /tmp/input-lan.txt root@${VM_IP}:/tmp/

  # Run hardening with input injection
  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-lan.txt
  REMOTE_EXIT=$?

  # Validate SSH access post-hardening
  ssh -o ConnectTimeout=5 root@${VM_IP} "ufw status | grep active" && echo "UFW_ENABLED=1"
  ssh root@${VM_IP} "test -f /var/log/homelab-hardening/run-*.log && echo LOG_EXISTS=1"
  ssh root@${VM_IP} "systemctl is-active ssh || systemctl is-active sshd" && echo "SSH_ACTIVE=1"
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - UFW status output with "Status: active"
  - Log file in `/var/log/homelab-hardening/run-*.log`
  - Post-hardening SSH login successful
  - Backup directory exists: `/var/backups/homelab-hardening/*/`

- **Rollback/Safety Steps:**
  - SSH known_hosts seed with VM SSH key before hardening
  - Pre-hardening SSH connectivity baseline test
  - Post-hardening: if SSH fails, VM is destroyed and run marked FAILED
  - UFW allow SSH before UFW enable is verified in logs
  - Collect UFW rules: `ufw show added` to verify SSH was whitelisted first

---

### P0: Idempotency & Rerun Safety

**Task:** Verify script is safe to rerun without side effects
- **Precondition:** Completed basic hardening flow (above)
- **Acceptance Criteria:**
  - Second run completes without errors (exit code 0)
  - SSH remains accessible
  - No duplicate rules/entries created
  - Config backups increment (no overwrites)
  - Same packages remain installed, no extras introduced

- **Exact Commands:**
  ```bash
  # Rerun with same inputs
  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-lan.txt
  REMOTE_EXIT=$?
  echo "Rerun exit code: ${REMOTE_EXIT}"
  REMOTE

  # Check for duplicate UFW rules
  ssh root@${VM_IP} "ufw show added | grep -c 'allow 22' | head -1"
  # Expected: 1 (not 2+)

  # Check backup count
  ssh root@${VM_IP} "ls -1 /var/backups/homelab-hardening/ | wc -l"
  # Expected: 2 backup directories (one per run)
  ```

- **Expected Artifacts:**
  - Exit code: `0` for rerun
  - UFW rule count for port 22: exactly `1`
  - Two timestamped backup directories in `/var/backups/homelab-hardening/`
  - New log file created with second run timestamp
  - SSH login successful post-rerun

---

## Profile-Specific Testing

### P0: Docker-Host Profile

**Task:** Verify `docker-host` profile hardening
- **Profile:** `docker-host`
- **Input Selections:** Install Docker, *do not* expose TLS API (safer), make choices
- **Acceptance Criteria:**
  - Docker installed and running (verify with `docker ps`)
  - SSH hardened and accessible
  - UFW rules allow SSH + Docker service ports
  - Checkmk optional step declined (N) in flow
  - Exit code 0

- **Exact Commands:**
  ```bash
  cat > /tmp/input-docker.txt <<'EOF'
  2
  y
  y
  n
  y
  y
  n
  y
  n
  y
  n
  n
  EOF

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-docker.txt
  REMOTE_EXIT=$?
  docker ps && echo "DOCKER_RUNNING=1"
  systemctl status docker && echo "DOCKER_SERVICE_ACTIVE=1"
  REMOTE
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - `docker ps` returns success and daemon running
  - Log shows Docker installation completed
  - SSH login successful
  - UFW rules include Docker daemon socket

---

### P0: File-Server Profile (Samba)

**Task:** Verify `file-server` (Samba) profile hardening
- **Profile:** `file-server`
- **Input Selections:** Install Samba, allow Samba ports, use "desired" encryption mode
- **Acceptance Criteria:**
  - Samba installed and running
  - UFW allows Samba ports (137-139, 445)
  - SMB encryption set to "desired" in config
  - SSH hardened and accessible
  - Exit code 0

- **Exact Commands:**
  ```bash
  cat > /tmp/input-fileserver.txt <<'EOF'
  3
  y
  y
  n
  y
  y
  y
  desired
  y
  n
  y
  n
  n
  EOF

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-fileserver.txt
  systemctl status smbd && echo "SAMBA_RUNNING=1"
  grep -i "server min protocol" /etc/samba/smb.conf && echo "SAMBA_CONFIG_SET=1"
  REMOTE
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - Samba daemon active (`systemctl status smbd`)
  - Samba config updated with encryption mode
  - UFW rules include Samba ports
  - SSH login successful

---

### P0: Tailscale-Gateway Profile (Advanced)

**Task:** Verify `tailscale-gateway` profile with inline Checkmk support
- **Profile:** `tailscale-gateway`
- **Input Selections:** Install Tailscale, enable subnet routing, skip Checkmk (N), no SSH restricted to tailscale0
- **Acceptance Criteria:**
  - Tailscale installed
  - `tailscale status` shows connected (or error message if not authed; that's OK for this test)
  - Subnet routing config passed (even if not activated without auth)
  - Checkmk inline step handled gracefully
  - Exit code 0
  - SSH remains accessible

- **Exact Commands:**
  ```bash
  cat > /tmp/input-tailscale.txt <<'EOF'
  6
  y
  y
  n
  y
  y
  y
  n
  n
  n
  y
  n
  n
  EOF

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-tailscale.txt
  REMOTE_EXIT=$?
  tailscale version && echo "TAILSCALE_INSTALLED=1"
  which tailscale && echo "TAILSCALE_BINARY_EXISTS=1"
  REMOTE
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - Tailscale binary present at `/usr/bin/tailscale`
  - Tailscale binary responds to `--version`
  - Log shows installation steps
  - SSH login successful

---

### P1: Public-Reverse-Proxy Profile

**Task:** Verify `public-reverse-proxy` profile hardening
- **Profile:** `public-reverse-proxy`
- **Input Selections:** Install Nginx, HTTPS-only mode, skip Certbot (N)
- **Acceptance Criteria:**
  - Nginx installed and running
  - UFW allows ports 80 and 443
  - SSH hardened and accessible
  - Exit code 0

- **Exact Commands:**
  ```bash
  cat > /tmp/input-webproxy.txt <<'EOF'
  5
  y
  y
  n
  y
  y
  y
  https-only
  n
  y
  n
  y
  n
  n
  EOF

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-webproxy.txt
  systemctl status nginx && echo "NGINX_RUNNING=1"
  ufw show added | grep -E "80|443" && echo "PORTS_ALLOWED=1"
  REMOTE
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - Nginx service active
  - UFW rules allow HTTP (80) and HTTPS (443)
  - SSH login successful
  - Logs show Nginx installation and Certbot skipped

---

## Checkmk Integration Tests

### P1: Checkmk Agent Installation (TLS Mode)

**Task:** Verify Checkmk TLS agent setup via `checkmk_setup.sh`
- **Precondition:** Hardening completed on fresh VM
- **Acceptance Criteria:**
  - Checkmk agent installed via `apt`
  - TLS certificates generated (check presence in `/etc/check_mk/`)
  - UFW allows port 6556 (TLS agent port) from expected source
  - Exit code 0
  - SSH remains accessible

- **Exact Commands:**
  ```bash
  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai

  # Run Checkmk setup interactively (TLS mode)
  bash checkmk_setup.sh <<'CHECKMK_INPUT'
  1
  1
  check-mk-monitoring.example.com
  monitoring
  yes
  CHECKMK_INPUT

  REMOTE_EXIT=$?
  dpkg -l | grep -i check-mk && echo "CHECKMK_AGENT_INSTALLED=1"
  test -f /etc/check_mk/agents/certs/* && echo "TLS_CERTS_EXIST=1"
  REMOTE
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - Checkmk agent package installed (verify `dpkg -l`)
  - TLS certificates in `/etc/check_mk/agents/certs/`
  - UFW rule for port 6556 added
  - SSH login successful
  - Log file created with setup details

---

### P1: Checkmk Plaintext Mode with Source Restriction

**Task:** Verify Checkmk plaintext agent with IP source restriction
- **Precondition:** Fresh VM with hardening applied
- **Acceptance Criteria:**
  - Checkmk agent installed
  - UFW allows port 6556 only from specified CIDR
  - Configuration logged for audit
  - Exit code 0
  - SSH access preserved

- **Exact Commands:**
  ```bash
  MONITOR_CIDR="192.0.2.0/24"  # Example monitoring subnet

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai

  bash checkmk_setup.sh <<'CHECKMK_INPUT'
  1
  2
  192.0.2.5
  monitoring
  n
  $(MONITOR_CIDR)
  y
  CHECKMK_INPUT

  REMOTE_EXIT=$?
  ss -lntu | grep 6556 && echo "CHECKMK_PORT_LISTENING=1"
  ufw show added | grep "6556"
  REMOTE
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - Port 6556 listening on TCP
  - UFW rule restricts source to specified CIDR
  - Logs document CIDR and firewall rule
  - SSH login successful

---

## Safety & SSH Lockout Prevention Tests

### P0: SSH Lockout Prevention - UFW Before Disable Password Auth

**Task:** Verify SSH allow rule is in place *before* password auth is disabled
- **Input:** Enable all hardening, *disable* password auth (only if key detected)
- **Acceptance Criteria:**
  - SSH allow rule exists in UFW *before* `PasswordAuthentication no` is set in sshd_config
  - Logs show SSH rule added before password auth change
  - SSH remains accessible post-hardening (public key auth works)
  - Exit code 0

- **Exact Commands:**
  ```bash
  # Pre-seed SSH key on VM
  ssh root@${VM_IP} "mkdir -p /root/.ssh && echo '$(cat ~/.ssh/id_rsa.pub)' >> /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"

  # Run hardening with password-auth disable
  cat > /tmp/input-sshkey-only.txt <<'EOF'
  1
  y
  y
  y
  y
  n
  y
  n
  n
  EOF

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-sshkey-only.txt

  # Check UFW rule order in logs
  grep -n "allow 22\|PasswordAuthentication no" /var/log/homelab-hardening/run-*.log
  # Expected: UFW rule line number < PasswordAuthentication line number
  REMOTE

  # Test key-based SSH access
  ssh -i ~/.ssh/id_rsa root@${VM_IP} "echo 'Key auth works'" && echo "SSH_KEY_AUTH_SUCCESS=1"
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - Logs show UFW rule before sshd_config password auth change
  - Public key SSH login succeeds
  - Password auth effectively disabled (`ssh -o PubkeyAuthentication=no` fails)
  - No SSH lockout

---

### P0: Custom SSH Port Hardening

**Task:** Verify SSH port change maintains accessibility
- **Input:** Change SSH port from 22 to 2222
- **Acceptance Criteria:**
  - Both port 22 and 2222 are UFW-allowed during transition (safety)
  - sshd listens on new port 2222
  - SSH login works on new port
  - Exit code 0

- **Exact Commands:**
  ```bash
  cat > /tmp/input-ssh-port.txt <<'EOF'
  1
  2222
  y
  y
  y
  n
  n
  y
  y
  n
  n
  EOF

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-ssh-port.txt

  # Verify both ports in UFW
  ufw show added | grep "allow.*22"
  ss -lntu | grep 2222
  REMOTE

  # Test SSH access on new port
  ssh -p 2222 root@${VM_IP} "echo 'Port 2222 works'" && echo "SSH_NEW_PORT_SUCCESS=1"
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - UFW allows both 22 and 2222 (transition safety)
  - sshd process listening on 2222
  - SSH login on port 2222 succeeds
  - No SSH lockout

---

### P1: Fail2Ban Integration (Rate Limiting)

**Task:** Verify Fail2Ban installation and SSH rate limiting
- **Input:** Enable Fail2Ban, SSH rate limiting enabled
- **Acceptance Criteria:**
  - Fail2Ban installed and running
  - sshd jail configured
  - Rate limiting rules applied
  - Exit code 0
  - SSH remains accessible

- **Exact Commands:**
  ```bash
  cat > /tmp/input-fail2ban.txt <<'EOF'
  1
  y
  y
  n
  y
  y
  y
  y
  y
  y
  n
  n
  EOF

  ssh root@${VM_IP} bash -s <<'REMOTE'
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-fail2ban.txt

  systemctl status fail2ban && echo "FAIL2BAN_ACTIVE=1"
  fail2ban-client status sshd && echo "FAIL2BAN_SSHD_JAIL=1"
  REMOTE
  ```

- **Expected Artifacts:**
  - Exit code: `0`
  - Fail2Ban service active
  - sshd jail configured and running
  - SSH login successful
  - Logs show Fail2Ban setup

---

## Rollback & Recovery Tests

### P1: Backup and Restore Sshd Config

**Task:** Verify backups allow safe recovery from conflicting sshd changes
- **Precondition:** Hardening applied with SSH port and password auth changes
- **Acceptance Criteria:**
  - Original sshd_config backed up before changes
  - Backup path is `/var/backups/homelab-hardening/<timestamp>/etc/ssh/sshd_config`
  - Restore procedure documented in logs
  - Exit code 0

- **Exact Commands:**
  ```bash
  ssh root@${VM_IP} bash -s <<'REMOTE'
  # Check backup structure
  find /var/backups/homelab-hardening -name "sshd_config" -type f
  # Expected: /var/backups/homelab-hardening/*/etc/ssh/sshd_config

  # Restore procedure (manual for safety)
  BACKUP_LATEST=$(ls -t /var/backups/homelab-hardening/ | head -1)
  cp /var/backups/homelab-hardening/${BACKUP_LATEST}/etc/ssh/sshd_config /etc/ssh/sshd_config.backup-$(date +%s)
  echo "Backup available at: /var/backups/homelab-hardening/${BACKUP_LATEST}/etc/ssh/sshd_config"
  REMOTE
  ```

- **Expected Artifacts:**
  - Backup directory with ISO timestamp exists
  - Original configs preserved in timestamped backup path
  - Restore instructions printed in logs
  - No automatic destructive restore (manual only)

---

### P1: UFW State Recovery

**Task:** Verify UFW state can be recovered from logs/backups if needed
- **Precondition:** UFW hardened and enabled
- **Acceptance Criteria:**
  - UFW rules can be exported/documented before changes
  - Logs capture all `ufw allow` additions
  - Recovery procedure is manual (not automatic)
  - Exit code 0

- **Exact Commands:**
  ```bash
  ssh root@${VM_IP} bash -s <<'REMOTE'
  # Export UFW state
  ufw show added > /tmp/ufw-rules-pre.txt

  # Run hardening
  cd /opt/hardening_system_ai
  bash system_hardening.sh < /tmp/input-lan.txt

  # Compare post-hardening
  ufw show added > /tmp/ufw-rules-post.txt
  diff -u /tmp/ufw-rules-pre.txt /tmp/ufw-rules-post.txt && echo "UFW_RULES_LOGGED=1"

  # Verify SSH rule not removed
  ufw show added | grep "allow.*22" && echo "SSH_RULE_PRESERVED=1"
  REMOTE
  ```

- **Expected Artifacts:**
  - Pre/post UFW rule export
  - Diff showing only incremental rules added
  - SSH rule preserved across runs
  - Logs document all UFW changes

---

## Artifact Collection & Reporting

### P1: Centralized Test Artifact Collection

**Task:** Collect all test outputs, logs, and state for analysis
- **Acceptance Criteria:**
  - Test run directory structure: `test-run-${TIMESTAMP}/`
  - Subdirectories per profile: `test-run-${TIMESTAMP}/${PROFILE}/`
  - Artifacts include: logs, config backups, UFW state, service status
  - Summary report generated with pass/fail per test
  - All artifacts timestamped and tagged with VM ID

- **Exact Commands:**
  ```bash
  ARTIFACTS_DIR="test-run-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${ARTIFACTS_DIR}/{logs,configs,ufw-rules,services}"

  ssh root@${VM_IP} bash -s <<'REMOTE'
  # Collect hardening logs
  cp -r /var/log/homelab-hardening/* ${ARTIFACTS_SCP_PATH}/logs/ 2>/dev/null || true

  # Collect configs
  cp /etc/ssh/sshd_config ${ARTIFACTS_SCP_PATH}/configs/
  cp /etc/ufw/ufw.conf ${ARTIFACTS_SCP_PATH}/configs/
  cp /etc/default/ufw ${ARTIFACTS_SCP_PATH}/configs/

  # Collect UFW state
  ufw show added > ${ARTIFACTS_SCP_PATH}/ufw-rules/added.txt
  ufw status verbose > ${ARTIFACTS_SCP_PATH}/ufw-rules/status.txt

  # Collect service status
  systemctl status ssh > ${ARTIFACTS_SCP_PATH}/services/ssh-status.txt 2>&1 || true
  systemctl status ufw > ${ARTIFACTS_SCP_PATH}/services/ufw-status.txt 2>&1 || true
  systemctl status fail2ban > ${ARTIFACTS_SCP_PATH}/services/fail2ban-status.txt 2>&1 || true
  REMOTE

  # SCP artifacts locally
  scp -r root@${VM_IP}:/tmp/artifacts/* "${ARTIFACTS_DIR}/"

  # Generate summary
  cat > "${ARTIFACTS_DIR}/SUMMARY.md" <<'EOF'
  # Test Run Summary
  - Timestamp: $(date -u)
  - VM IP: ${VM_IP}
  - Profile: ${PROFILE}
  - Exit Code: ${EXIT_CODE}
  - SSH Status: ${SSH_STATUS}
  - UFW Status: ${UFW_STATUS}
  - Test Result: ${RESULT}
  EOF
  ```

- **Expected Artifacts:**
  - Directory tree: `test-run-${TIMESTAMP}/{logs,configs,ufw-rules,services}/`
  - Log files: `hardening/run-*.log`, `fail2ban.log`
  - Config snapshots: `sshd_config`, `ufw.conf`
  - UFW state: `added.txt`, `status.txt`
  - Service status: `ssh-status.txt`, `ufw-status.txt`, `fail2ban-status.txt`
  - Summary report: `SUMMARY.md`

---

## Test Execution Matrix

| Priority | Profile | Test Type | Input Mode | Expected Exit Code | SSH Access | Notes |
|----------|---------|-----------|-----------|-------------------|-----------|-------|
| P0 | lan-only | Basic flow | Scripted | 0 | Yes | Minimum hardening |
| P0 | lan-only | Idempotency | Scripted (2x) | 0 | Yes | No side effects on rerun |
| P0 | docker-host | Profile test | Scripted | 0 | Yes | Docker service validation |
| P0 | file-server | Profile test | Scripted | 0 | Yes | Samba hardening |
| P0 | tailscale-gateway | Profile test | Scripted | 0 | Yes | Tailscale binary present |
| P0 | SSH lockout prevention | Safety test | Scripted | 0 | Yes (key) | Password auth disabled safely |
| P0 | SSH custom port | Safety test | Scripted | 0 | Yes | Port change with UFW safety |
| P1 | public-reverse-proxy | Profile test | Scripted | 0 | Yes | Nginx + web hardening |
| P1 | media-host | Profile test | Scripted | 0 | Yes | Plex/media config |
| P1 | Checkmk TLS | Integration | Scripted | 0 | Yes | Agent + certs |
| P1 | Checkmk plaintext | Integration | Scripted | 0 | Yes | Port + CIDR restriction |
| P1 | Fail2Ban | Security service | Scripted | 0 | Yes | Rate limiting |
| P1 | UFW rollback | Recovery | Manual commands | 0 | Yes | Backup/restore procedure |

---

## Pre-Test Checklist

- [ ] Cloud provider credentials configured (SSH key, API token)
- [ ] Ubuntu 22.04 LTS or Debian 12 image ID confirmed
- [ ] Test runner VM has network access to provision/proxy
- [ ] Git repo cloned locally for input file generation
- [ ] SSH key pair generated and registered with cloud provider
- [ ] Artifact collection paths prepared (`test-run-*` directories)
- [ ] Cleanup/destroy scripts written to guarantee VM removal after tests
- [ ] Monitoring/health checks pass on fresh VM before hardening tests start
- [ ] Ansible/Terraform code reviewed if using IaC for provisioning

---

## Post-Test Cleanup

**Critical:** All cloud VMs must be destroyed after tests to prevent cost accumulation.

```bash
# Cleanup script template
TIMESTAMP="<test_run_timestamp>"
ARTIFACTS_DIR="test-run-${TIMESTAMP}"

# Iterate through inventory and destroy all VMs
while read -r VM_ID VM_IP; do
  doctl compute droplet delete "${VM_ID}" --force
  echo "Destroyed VM ${VM_ID}"
done < "${ARTIFACTS_DIR}/vm-inventory.txt"

# Verify no orphaned resources
doctl compute droplet list | grep hardening && echo "WARNING: Orphaned VMs remain"

# Archive test run results
tar -czf "${ARTIFACTS_DIR}.tar.gz" "${ARTIFACTS_DIR}/"
echo "Test artifacts archived: ${ARTIFACTS_DIR}.tar.gz"
```

---

## Success Criteria (Overall)

✓ All P0 tests pass (exit code 0, SSH accessible post-hardening)
✓ All P1 tests pass (integration and advanced scenarios)
✓ At least 2 concurrent profile test runs without interference
✓ Logs/backups properly created and retrievable
✓ Zero SSH lockout events across test matrix
✓ All cloud VMs cleaned up (no orphaned resources)
✓ Artifact directory contains all required logs and configs
✓ All tests reproducible with exact commands in this TODO

---

## Notes for Codex Agent

- Each task is independent and can run in parallel (provision 4-6 VMs concurrently)
- Input files are generated per profile; customize the stdin sequences for edge cases
- SSH connectivity is critical: test pre/post hardening immediately
- Rollback procedures are *manual only* — no automatic restore to prevent accidental data loss
- Collect artifacts liberally; logs are your audit trail for debugging failures
- Tag all test runs with `RUN_ID=$(date +%s)` to ensure unique, timestamped test directories
