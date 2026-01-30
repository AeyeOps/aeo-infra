# Case Study: Three-Node Mesh Implementation

Real-world implementation of a heterogeneous mesh network across Linux, Windows, and WSL2.

## Scenario

**Goal:** Establish full bidirectional connectivity (SSH + shared storage) across three nodes:
- Linux workstation (ARM64, Ubuntu)
- Windows 11 desktop (x64)
- WSL2 guest on the Windows machine

**Requirements:**
1. SSH access between all nodes by hostname (not IP)
2. Shared directory accessible from all nodes
3. Persistent configuration that survives reboots
4. Protection against accidental misconfiguration by AI coding assistants

## Contents

| Document | Description |
|----------|-------------|
| [JOURNEY.md](JOURNEY.md) | Chronological implementation story |
| [LESSONS-LEARNED.md](LESSONS-LEARNED.md) | Key insights and gotchas |
| [WINDOWS-CREDENTIALS.md](WINDOWS-CREDENTIALS.md) | Deep dive: Windows credential isolation |
| [WSL-SSH.md](WSL-SSH.md) | Deep dive: WSL2 SSH port conflicts |
| [AGENT-PROTECTION.md](AGENT-PROTECTION.md) | Protecting infrastructure from AI agents |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Tailscale Mesh (100.64.x.x)                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │ linux-host   │    │ windows-host │    │  wsl-guest   │      │
│  │              │    │              │    │              │      │
│  │ SSH: 22      │    │ SSH: 22      │    │ SSH: 2222    │      │
│  │ Samba: 445   │    │ RDP: 3389    │    │ (shares IP)  │      │
│  │ NFS: 2049    │    │              │    │              │      │
│  └──────────────┘    └──────────────┘    └──────────────┘      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Final Connectivity Matrix

| From → To | SSH Command | File Access |
|-----------|-------------|-------------|
| linux → windows | `ssh windows` | RDP for GUI |
| linux → wsl | `ssh wsl` | NFS mount |
| windows → linux | `ssh linux-host` | Z: drive (SMB) |
| wsl → linux | `ssh linux-host` | NFS mount |

## Time Investment

This implementation took approximately 4 hours of troubleshooting, primarily due to:
- Windows credential isolation between session types (60% of time)
- WSL2 SSH port conflicts with Windows OpenSSH (20% of time)
- Firewall rule configuration across systems (15% of time)
- Documentation and protection setup (5% of time)

## Key Success Factors

1. **Tailscale for mesh networking** - Handles NAT traversal, provides stable IPs
2. **SSH configs with aliases** - `ssh windows` instead of remembering IPs
3. **Multiple file sharing protocols** - Samba for Windows, NFS for Linux/WSL
4. **Startup folder over scheduled tasks** - Runs in user's credential context
5. **Agent protection documentation** - Prevents future breakage
