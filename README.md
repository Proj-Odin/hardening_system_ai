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
An **interactive, menu-driven** system hardening script for **Debian and Ubuntu** homelab servers. Features:
- **Profile-based configuration**: lan-only, docker-host, file-server, media-host, public-reverse-proxy, tailscale-gateway, custom
- **Interactive prompts** for all major choices with safe defaults
- **Backup system** for configuration files before changes
- **Summary screen** before applying changes
- **SSH safety checks** to avoid lockouts
- **TLS preference** where applicable
- **Cross-distribution compatibility** (automatic detection)
- **Optional Checkmk integration** for all profiles
- **Semi-automated update notifications** via apticron
- **Comprehensive logging** to timestamped files

**New Interactive Features:**
- Menu-driven profile selection
- Step-by-step configuration with confirmations
- Profile-specific firewall rules and services
- TLS-enabled monitoring options
- Safety warnings and validation checks

**Usage:**
```bash
sudo ./system_hardening.sh
```

**Supported Profiles:**
- **lan-only**: Basic LAN server with SSH access
- **docker-host**: Docker container host with Swarm support
- **file-server**: Samba file sharing server
- **media-host**: Plex media streaming server
- **public-reverse-proxy**: Nginx reverse proxy for public services
- **tailscale-gateway**: Tailscale subnet router with identity-aware access
- **custom**: Fully customizable configuration

**Safety Features:**
- Automatic SSH key validation before disabling passwords
- Configuration file backups with timestamps
- Summary confirmation before applying changes
- Distribution and service detection
- Graceful handling of missing packages

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

## Interactive Homelab Hardening Script - Design Document

### Updated Script Structure

```
system_hardening.sh (v2.0-interactive)
├── Global Variables & Configuration
│   ├── Profile definitions (lan-only, docker-host, etc.)
│   ├── Safety variables (backups, logging, confirmation)
│   └── Environment detection (distro, SSH service)
├── Interactive Menu System
│   ├── Profile selection menu
│   ├── Configuration prompts (SSH, firewall, security, Checkmk)
│   └── Summary & confirmation screen
├── Core Functions
│   ├── detect_environment() - Distro & service detection
│   ├── backup_config() - Safe config file backups
│   ├── check_ssh_keys_working() - SSH safety validation
│   ├── show_menu() & get_user_choice() - Menu system
│   └── confirm_action() - Yes/no prompts with defaults
├── Configuration Modules
│   ├── select_profile() - Profile selection
│   ├── configure_ssh() - SSH hardening prompts
│   ├── configure_firewall() - UFW rules by profile
│   ├── configure_security_services() - Fail2Ban, AppArmor, updates
│   └── configure_checkmk() - Optional monitoring setup
├── Summary & Safety
│   ├── show_summary() - Display planned changes
│   └── Safety validations before apply
└── Implementation Functions
    ├── apply_changes() - Execute hardening
    ├── Profile-specific setup functions
    └── Logging & error handling
```

### New Interactive Menu Flow

```
1. Initial Setup
   └── Detect environment (distro, SSH service)
   
2. Profile Selection Menu
   ├── lan-only
   ├── docker-host  
   ├── file-server
   ├── media-host
   ├── public-reverse-proxy
   ├── tailscale-gateway
   └── custom
   
3. SSH Configuration
   ├── Port selection (default: 22, recommend non-standard)
   ├── Root login disable (default: yes)
   ├── Password auth (only if SSH keys detected)
   └── Rate limiting (default: yes)
   
4. Firewall Configuration
   ├── Base SSH rule
   ├── Profile-specific rules (Docker ports, Samba, etc.)
   └── Custom port additions
   
5. Security Services
   ├── Fail2Ban (default: yes)
   ├── AppArmor (default: yes)
   └── Update management (notifications vs unattended)
   
6. Checkmk Integration (Optional)
   ├── Agent installation
   ├── Server configuration
   ├── TLS preference
   └── Firewall rules
   
7. Summary Screen
   └── Confirm before applying changes
   
8. Implementation
   └── Apply changes with logging & backups
```

### New Functions/Modules Added

#### Menu System Functions
- `show_menu(title, options[])` - Display numbered menu
- `get_user_choice(prompt, default, max_choices)` - Get validated menu choice
- `confirm_action(prompt, default)` - Yes/no confirmation with safety defaults

#### Safety & Validation Functions
- `backup_config(file)` - Backup configs with timestamps
- `check_ssh_keys_working()` - Validate SSH key auth before disabling passwords
- `validate_port(port)` - Port number validation

#### Profile-Specific Functions
- `apply_profile_specific()` - Install profile-required packages
- Profile firewall rule generators
- Service-specific configurations

#### Checkmk Integration
- `configure_checkmk()` - Interactive Checkmk setup
- `install_checkmk()` - Agent installation with TLS options
- Firewall rule management for monitoring

### Prompt Text for Each Interactive Question

#### Profile Selection
```
=== Homelab Server Profiles ===
1. lan-only
2. docker-host
3. file-server
4. media-host
5. public-reverse-proxy
6. tailscale-gateway
7. custom

Select your server profile [1]:
```

#### SSH Configuration
```
=== SSH Configuration ===

SSH port (avoid 22 for security) [22]:

Disable root SSH login? (y/n) [y]:

SSH key authentication appears to be configured.
Disable password authentication for SSH? (y/n) [y]:

Enable SSH rate limiting (recommended)? (y/n) [y]:
```

#### Firewall Configuration
```
=== Firewall Configuration ===

Allow Docker Swarm ports (2376, 2377, 7946, 4789)? (y/n) [n]:
Allow Samba ports (137,138,139,445)? (y/n) [y]:
Allow Plex media server port (32400)? (y/n) [y]:

Add custom firewall rules? (y/n) [n]:
Enter additional ports (comma-separated, e.g., '8080,8443'):
```

#### Security Services
```
=== Security Services ===

Install and configure Fail2Ban (recommended)? (y/n) [y]:
Enable AppArmor (recommended for Ubuntu)? (y/n) [y]:

=== Update Management ===
Choose update approach:
1. Semi-automated (notifications only, manual install)
2. Unattended upgrades (automatic, not recommended for production)
3. Manual only (no automation)

Update approach [1]:
WARNING: Unattended upgrades can break things. Continue? (y/n) [n]:
```

#### Checkmk Integration
```
=== Checkmk Monitoring (Optional) ===

Install Checkmk agent for monitoring? (y/n) [n]:

Checkmk agent URL:
Enter Checkmk agent .deb URL:

Checkmk server IP (leave empty for no restriction):
Server IP:

Checkmk site name [monitoring]:

Use TLS for Checkmk agent communication? (y/n) [y]:
```

#### Final Confirmation
```
==========================================
HOMELAB HARDENING SUMMARY
==========================================
Profile: docker-host
Distribution: ubuntu
SSH service: ssh
Log file: /var/log/homelab_hardening-20260313_143022.log
Backup directory: /var/backups/homelab_hardening/20260313_143022/

SSH Configuration:
  Port: 2222
  Root login: Disabled
  Password auth: Disabled
  Rate limiting: Enabled

Firewall (UFW):
  Rules: ssh:2222,2376,2377,7946,4789

Security Services:
  Fail2Ban: Install
  AppArmor: Enable
  Updates: Semi-automated (apticron notifications)

Checkmk Monitoring:
  Agent URL: https://checkmk.example.com/agent.deb
  Server IP: 192.168.1.100
  Site: monitoring
  TLS: Enabled
==========================================

Apply these changes? (y/n) [n]:
```

### Implementation Notes

#### Safety Features
- **SSH Lockout Prevention**: Validates SSH keys exist before disabling password auth
- **Configuration Backups**: All modified files backed up with timestamps
- **Confirmation Required**: Summary screen requires explicit confirmation
- **Distribution Detection**: Automatic adaptation for Debian/Ubuntu differences
- **Graceful Degradation**: Handles missing packages without failing

#### TLS Implementation
- **Checkmk Agent**: Prompts for TLS preference, configures accordingly
- **Future Extensions**: Framework ready for HTTPS certificate management
- **Service Publishing**: Profile-specific TLS-capable service setup

#### Profile-Specific Logic
- **Docker Host**: Adds Swarm ports, installs Docker if needed
- **File Server**: Samba port configuration, service setup
- **Media Host**: Plex port configuration
- **Reverse Proxy**: Nginx + Certbot framework
- **Tailscale Gateway**: Tailscale installation and configuration

#### Logging & Debugging
- **Comprehensive Logs**: All actions logged with timestamps
- **Backup Tracking**: Backup locations logged and displayed
- **Error Recovery**: Script can be rerun safely (idempotent operations)

### Safety Warnings

#### Critical Safety Measures
1. **SSH Access Verification**: Script validates SSH key authentication before disabling passwords
2. **Backup Requirements**: All configuration changes backed up automatically
3. **Confirmation Mandatory**: No changes applied without explicit user confirmation
4. **Distribution Compatibility**: Tested on Debian/Ubuntu, warns for others

#### Profile-Specific Warnings
- **Public Reverse Proxy**: Warns about security implications of public exposure
- **Tailscale Gateway**: Emphasizes identity-aware access benefits
- **Unattended Upgrades**: Strong warning about potential service disruption

#### Operational Safety
- **Test Environment First**: Always test hardening in non-production first
- **Backup Verification**: Verify backups are restorable before proceeding
- **Monitoring Setup**: Ensure monitoring is working before considering production use
- **Rollback Planning**: Have manual recovery procedures ready

#### TLS Security Notes
- **Certificate Management**: Automated where possible, manual for complex setups
- **Mixed Security**: Clearly labels TLS vs non-TLS configurations
- **Upgrade Paths**: Framework supports future TLS enhancements

This interactive design provides maximum safety while offering comprehensive hardening options for homelab servers.

## License

GPL v3 (see LICENSE file)