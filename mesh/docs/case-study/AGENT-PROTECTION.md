# Protecting Infrastructure from AI Agents

How to prevent AI coding assistants from accidentally breaking critical infrastructure.

## The Problem

AI coding assistants (Claude Code, GitHub Copilot, Cursor, etc.) are helpful but can be overzealous when troubleshooting. Given a network connectivity issue, they might:

- Modify SSH configs to "fix" them
- Change firewall rules
- Restart services
- Alter system configurations

When the infrastructure is working correctly and the issue is elsewhere, these "fixes" can break things.

## Case Study: SSH Config Destruction

During this mesh setup, while troubleshooting an unrelated NFS issue, an AI assistant:

1. Observed SSH connection attempts failing (due to a temporary network issue)
2. "Fixed" the SSH config by removing custom port settings
3. Broke WSL SSH connectivity (which requires port 2222)
4. Required 30+ minutes to debug and restore

## Protection Strategy

### 1. Document in CLAUDE.md / AGENTS.md

Create documentation files that AI assistants are trained to read and respect.

**~/.claude/CLAUDE.md** (user's home directory):
```markdown
# Network Infrastructure - DO NOT MODIFY

The following configurations are WORKING and must not be changed:

## SSH Configuration (~/.ssh/config)
- Custom hosts: windows, wsl, linux-host
- Custom ports configured for WSL (2222)
- DO NOT modify, regenerate, or "fix" this file

## Mesh Network
- Tailscale mesh is configured and working
- Headscale coordination server running on linux-host
- DO NOT restart, reconfigure, or modify tailscale/headscale

## If Something Appears Broken
1. Check if the target machine is powered on
2. Check `tailscale status` on both ends
3. Check if the service is running (`systemctl status sshd`)
4. ASK THE USER before modifying any config
```

### 2. Create AGENTS.md with Explicit Warnings

**~/.claude/AGENTS.md**:
```markdown
# ⚠️ CRITICAL: Infrastructure Protection Rules

## NEVER Modify Without Explicit User Request:
- SSH configs (~/.ssh/config)
- Firewall rules (ufw, iptables, Windows Firewall)
- System services (systemd units)
- Tailscale/Headscale configuration
- Samba/NFS exports

## Before Troubleshooting Network Issues:
1. READ this file
2. ASK the user if the mesh network was working before
3. CHECK if the issue is transient (retry a few times)
4. VERIFY the service is running before assuming config is wrong

## Working Infrastructure (as of YYYY-MM-DD):
- SSH to windows: working (port 22)
- SSH to wsl: working (port 2222)
- SSH to linux-host: working (port 22)
- Samba share: working (\\linux-host\shared)
- NFS mount: working (linux-host:/opt/shared)
```

### 3. Deploy to All Machines

Place these files on every machine in the mesh:

| Machine | CLAUDE.md Location | AGENTS.md Location |
|---------|-------------------|-------------------|
| Linux | ~/.claude/CLAUDE.md | ~/.claude/AGENTS.md |
| Windows | %USERPROFILE%\.claude\CLAUDE.md | %USERPROFILE%\.claude\AGENTS.md |
| WSL | ~/.claude/CLAUDE.md | ~/.claude/AGENTS.md |

### 4. Add Project-Level Protection

For project directories, add infrastructure notes to the project's CLAUDE.md:

```markdown
# Project CLAUDE.md

## Network Dependencies
This project requires the mesh network. See ~/.claude/AGENTS.md for details.

DO NOT troubleshoot network issues by modifying system configs.
```

## Template Files

### CLAUDE.md Template

```markdown
# Network Infrastructure - DO NOT MODIFY

## Overview
Three-node mesh network: linux-host, windows-host, wsl-guest
Connected via Tailscale/Headscale mesh (100.64.x.x)

## SSH Configuration
- linux-host: Port 22
- windows-host: Port 22  
- wsl-guest: Port 2222 (shares IP with windows-host)

## File Sharing
- Samba: linux-host:/opt/shared → Windows Z: drive
- NFS: linux-host:/opt/shared → WSL /mnt/shared

## ⚠️ DO NOT MODIFY
- ~/.ssh/config
- /etc/ssh/sshd_config*
- Firewall rules
- Tailscale configuration
- Samba configuration (/etc/samba/smb.conf)
- NFS exports (/etc/exports)

## Troubleshooting Protocol
1. Verify target is online: `ping <hostname>`
2. Verify mesh: `tailscale status`
3. Verify service: `systemctl status <service>`
4. If still broken: ASK USER, do not modify configs
```

### AGENTS.md Template

```markdown
# ⚠️ AI AGENTS: READ BEFORE TAKING ACTION

## Protected Infrastructure
This machine is part of a configured mesh network.
Network configs have been tested and verified working.

## FORBIDDEN Actions (unless explicitly requested):
1. Modifying ~/.ssh/config
2. Changing SSH service configuration
3. Altering firewall rules
4. Restarting network services
5. Modifying Tailscale/Headscale settings
6. Changing file sharing configs (Samba/NFS)

## When Network Issues Occur:
FIRST: Assume the config is correct and something else is wrong
THEN: Check transient issues (service down, machine off, network blip)
FINALLY: ASK the user before modifying any configuration

## Current Working State:
Last verified: YYYY-MM-DD
- SSH: All hosts reachable by name
- Shares: All mounts working
- Mesh: All nodes connected
```

## Effectiveness

This approach is not foolproof, but significantly reduces accidental damage:

1. **AI assistants read CLAUDE.md** - It's a recognized convention
2. **Explicit warnings create hesitation** - Agents are less likely to modify clearly marked files
3. **Troubleshooting protocol** - Guides agents toward non-destructive diagnosis
4. **Documentation serves humans too** - Team members know what not to touch

## Maintenance

Update the "Last verified" date periodically to confirm the documentation reflects reality. If configurations do need to change, update the protection docs accordingly.
