# CLAUDE.md

This file provides guidance to Claude Code when working with aeo-infra.

## Repository Structure

```
aeo-infra/
├── mesh/          # Python CLI for mesh networking (self-contained project)
│   ├── src/mesh/  # Python package
│   ├── pyproject.toml
│   └── README.md  # Mesh-specific docs
└── vms/           # Bash scripts for VM management
    ├── vm.sh      # Main CLI
    ├── lib/       # Shell libraries
    └── README.md  # VM-specific docs
```

## Mesh Networking (mesh/)

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  sfspark1 (GB10) - Headscale Coordination Server            │
│  ├─ headscale serve (port 8080)                            │
│  ├─ Tailscale client (connects to localhost:8080)          │
│  └─ Syncthing instance (port 8384/22000)                   │
└─────────────────────────────────────────────────────────────┘
              ↓ WireGuard mesh (peer-to-peer, encrypted)
┌─────────────────────────────────────────────────────────────┐
│  office-one (Windows + WSL2) - Tailscale Clients            │
│  ├─ WSL2 Tailscale (connects to sfspark1:8080)             │
│  │   └─ Syncthing (port 8385/22001)                        │
│  └─ Windows Tailscale (connects to sfspark1:8080)          │
│      └─ Syncthing (port 8386/22002)                        │
└─────────────────────────────────────────────────────────────┘
```

### Key Commands

```bash
cd /opt/dev/aeo/aeo-infra/mesh

# Development
uv sync
uv run mesh --help

# Server (sfspark1 only)
uv run mesh server setup
uv run mesh server keygen
uv run mesh server status

# Client (all machines)
uv run mesh client setup --server http://sfspark1.local:8080 --key <KEY>
uv run mesh client join --key <KEY>

# Status
uv run mesh status
uv run mesh status --verbose
```

### Network Configuration

| Machine | SSH Port | Syncthing GUI | Syncthing Sync | Headscale |
|---------|----------|---------------|----------------|-----------|
| sfspark1 | 22 | 8384 | 22000 | 8080 (server) |
| office-one (WSL2) | 2222 | 8385 | 22001 | - |
| Windows | 22 | 8386 | 22002 | - |

### Shared Folder Paths
- sfspark1: `/opt/shared`
- WSL2: `/opt/shared`
- Windows: `C:\shared`

### Troubleshooting

**Headscale server not running:**
```bash
sudo systemctl status headscale
sudo systemctl start headscale
```

**Tailscale client not connecting:**
1. Verify Headscale is running: `curl http://sfspark1.local:8080/health`
2. Get new pre-auth key: `uv run mesh server keygen`
3. Re-join: `uv run mesh client join --key NEW_KEY`

**Syncthing devices not connecting:**
1. Verify device IDs are exchanged
2. Check firewall allows ports 22000-22002
3. Verify folder is shared in Syncthing GUI

## VM Management (vms/)

### Key Commands

```bash
cd /opt/dev/aeo/aeo-infra/vms

# Ubuntu VM
sudo ./setup-ubuntu-vm.sh           # One-time setup
sudo ./start-ubuntu-vm.sh install   # First boot with ISO
sudo ./start-ubuntu-vm.sh           # Normal boot
sudo ./stop-ubuntu-vm.sh            # Graceful shutdown

# Windows VM
sudo ./start-windows-vm.sh
sudo ./stop-windows-vm.sh

# Network setup (run at boot or before VMs)
sudo ./setup-vm-network.sh
```

### VM Network

VMs use a bridge network with NAT to the host's physical interface:

| VM | IP Address | VNC Port | QEMU Monitor |
|----|------------|----------|--------------|
| Windows | 192.168.50.11 | 5900 | 7100 |
| Ubuntu | 192.168.50.10 | 5901 | 7101 |

Gateway: `192.168.50.1` (host bridge)

### /storage/ Files

| File | Purpose |
|------|---------|
| `windows.rom` | UEFI firmware (shared, read-only) |
| `windows.vars` | Windows UEFI variables |
| `data.img` | Windows disk |
| `ubuntu.img` | Ubuntu disk (64GB) |
| `ubuntu.vars` | Ubuntu UEFI variables |
| `*.iso` | Installation media |

### QEMU Monitor

Connect via telnet for VM control:
```bash
telnet localhost 7100  # Windows
telnet localhost 7101  # Ubuntu
```

Commands: `info status`, `system_powerdown`, `quit`

## Directives

- Validate before declaring root cause/solution
- Request user validation for hardware/UI tests - no automated tests exist
- MINIMAL COMPLEXITY: Prefer existing tools over custom code
- Version source of truth: pyproject.toml (mesh), scripts (vms)
