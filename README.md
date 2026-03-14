# System Hardening and Checkmk Setup Scripts

This repository contains scripts for system hardening and setting up Checkmk monitoring on Debian/Ubuntu systems.

## Existing Scripts

### declawer_v1.0.sh
A comprehensive hardening script for Debian/Ubuntu guest VMs. Features:
- SSH hardening (custom port, key-only auth, disable root login)
- UFW firewall configuration
- Fail2Ban installation and configuration
- OpenClaw gateway setup
- Admin user creation with SSH keys
- Node.js 22 installation

### setup_v1.5.sh / setup.sh
Setup script for HDD burn-in testing systems. Features:
- SSH configuration
- UFW firewall setup
- Checkmk agent installation
- SMART monitoring plugins
- Wake-on-LAN configuration
- Local checks for burn-in status

## New Scripts

### system_hardening.sh
A general-purpose system hardening script for **Debian and Ubuntu** servers. Features:
- SSH hardening with configurable options
- UFW firewall setup
- Fail2Ban configuration
- Semi-automated update notifications (apticron)
- Additional security measures
- Automatic detection of distribution and SSH service names

**Usage:**
```bash
sudo ./system_hardening.sh
```

**Environment Variables:**
- `SSH_PORT`: SSH port (default: 22)
- `DISABLE_ROOT_SSH`: Disable root SSH login (default: 1)
- `ALLOW_PASSWORD_AUTH`: Allow password authentication (default: 0)
- `INSTALL_FAIL2BAN`: Install Fail2Ban (default: 1)
- `INSTALL_UNATTENDED_UPGRADES`: Install unattended-upgrades (default: 0, disabled for safety)
- `INSTALL_APT_NOTIFICATIONS`: Install apticron for update notifications (default: 1)
- `NONINTERACTIVE`: Run without prompts (default: 0)

### checkmk_setup.sh
Script to install and configure Checkmk agent for monitoring. Features:
- Checkmk agent installation from .deb URL
- Firewall configuration for agent port (6556)
- SMART monitoring plugins
- Additional plugins (systemd units)
- Local security checks
- Registration instructions

**Usage:**
```bash
sudo ./checkmk_setup.sh
```

**Required Environment Variables:**
- `CMK_AGENT_DEB_URL`: URL to Checkmk agent .deb file

**Optional Environment Variables:**
- `CMK_SERVER_IP`: Restrict agent access to this IP
- `CMK_SITE`: Checkmk site name (default: monitoring)
- `FORCE_REINSTALL`: Force agent reinstall (default: 0)
- `INSTALL_SMART_PLUGINS`: Install SMART plugins (default: 1)
- `NONINTERACTIVE`: Run without prompts (default: 0)

## Example Usage

### Basic Hardening (with update notifications)
```bash
sudo ./system_hardening.sh
```

### Hardening with Custom SSH Port
```bash
SSH_PORT=2222 sudo ./system_hardening.sh
```

### Hardening with Unattended Upgrades (not recommended for production)
```bash
INSTALL_UNATTENDED_UPGRADES=1 INSTALL_APT_NOTIFICATIONS=0 sudo ./system_hardening.sh
```

### Minimal Hardening (no update automation)
```bash
INSTALL_FAIL2BAN=0 INSTALL_APT_NOTIFICATIONS=0 sudo ./system_hardening.sh
```

### Checkmk Setup
```bash
CMK_AGENT_DEB_URL="http://checkmk.example.com/monitoring/check_mk/agents/check-mk-agent_2.4.0p12-1_all.deb" \
CMK_SERVER_IP="192.168.1.100" \
sudo ./checkmk_setup.sh
```

### Combined Setup
```bash
# First harden the system
sudo ./system_hardening.sh

# Then set up monitoring
CMK_AGENT_DEB_URL="..." CMK_SERVER_IP="..." sudo ./checkmk_setup.sh
```

## Update Management

The hardening script uses a **semi-automated approach** by default:

- **apticron**: Sends daily email notifications about available updates to root
- **No automatic installation**: You control when updates are applied
- **Optional unattended-upgrades**: Can be enabled if desired (not recommended for production)

### Checking for Updates
```bash
# Manual check
apt update && apt list --upgradable

# Test notification system
sudo apticron
```

### Applying Updates
```bash
# Review and apply updates manually
sudo apt update
sudo apt list --upgradable
sudo apt upgrade
```

### Configuring Email Notifications
Edit `/etc/apticron/apticron.conf` to set the notification email address:
```bash
EMAIL="admin@example.com"
```

## Compatibility

The scripts are designed to work on:
- **Debian** (all current versions)
- **Ubuntu** (all current versions)

The hardening script automatically detects the distribution and adjusts service names accordingly (e.g., SSH service may be `ssh` on Ubuntu or `sshd` on some Debian versions).

## Security Notes

- Always review scripts before running in production
- Test in a non-production environment first
- Customize firewall rules according to your network requirements
- Regularly update systems and review logs
- Consider additional hardening measures based on your threat model
- **Update Management**: The script enables update notifications by default. Review available updates regularly and test in staging before production deployment.

## License

GPL v3 (see LICENSE file)