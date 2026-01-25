# CLAUDE.md

This file provides guidance to Claude Code when working with aeo-infra.

## Repository Structure

```
aeo-infra/
├── .env.example   # Configuration template
├── .env           # Local config (gitignored)
├── mesh/          # Python CLI for mesh networking (self-contained project)
│   ├── src/mesh/  # Python package
│   ├── pyproject.toml
│   └── README.md  # Mesh-specific docs
└── vms/           # Bash scripts for VM management
    ├── vm.sh      # Main CLI
    ├── lib/       # Shell libraries
    └── README.md  # VM-specific docs
```

## Configuration

Environment variables (set in `.env` or shell):
- `MESH_DEFAULT_USER` - Default SSH username
- `MESH_SERVER_HOST` - Headscale server hostname
- `MESH_SHARED_FOLDER_LINUX` - Linux shared folder path
- `MESH_SHARED_FOLDER_WINDOWS` - Windows shared folder path
- `VM_STORAGE_DIR` - VM disk storage directory
- `VM_SUBNET` - VM bridge subnet prefix

## Mesh Networking (mesh/)

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Server - Headscale Coordination Server                     │
│  ├─ headscale serve (port 8080)                            │
│  ├─ Tailscale client (connects to localhost:8080)          │
│  └─ Syncthing instance (port 8384/22000)                   │
└─────────────────────────────────────────────────────────────┘
              ↓ WireGuard mesh (peer-to-peer, encrypted)
┌─────────────────────────────────────────────────────────────┐
│  Clients - Tailscale Clients                                │
│  ├─ WSL2 Tailscale (connects to server:8080)               │
│  │   └─ Syncthing (port 8385/22001)                        │
│  └─ Windows Tailscale (connects to server:8080)            │
│      └─ Syncthing (port 8386/22002)                        │
└─────────────────────────────────────────────────────────────┘
```

### Key Commands

```bash
cd mesh

# Development
uv sync
uv run mesh --help

# Server (coordination server only)
uv run mesh server setup
uv run mesh server keygen
uv run mesh server status

# Client (all machines)
uv run mesh client setup --server http://<server>:8080 --key <KEY>
uv run mesh client join --key <KEY>

# Status
uv run mesh status
uv run mesh status --verbose
```

### Network Configuration

| Role | SSH Port | Syncthing GUI | Syncthing Sync | Headscale |
|------|----------|---------------|----------------|-----------|
| Server | 22 | 8384 | 22000 | 8080 |
| WSL2 | 2222 | 8385 | 22001 | - |
| Windows | 22 | 8386 | 22002 | - |

### Shared Folder Paths
- Linux: `$MESH_SHARED_FOLDER_LINUX` (default: `/opt/shared`)
- Windows: `$MESH_SHARED_FOLDER_WINDOWS` (default: `C:\shared`)

### Troubleshooting

**Headscale server not running:**
```bash
sudo systemctl status headscale
sudo systemctl start headscale
```

**Tailscale client not connecting:**
1. Verify Headscale is running: `curl http://<server>:8080/health`
2. Get new pre-auth key: `uv run mesh server keygen`
3. Re-join: `uv run mesh client join --key NEW_KEY`

**Syncthing devices not connecting:**
1. Verify device IDs are exchanged
2. Check firewall allows ports 22000-22002
3. Verify folder is shared in Syncthing GUI

## VM Management (vms/)

### Key Commands

```bash
cd vms

# Unified CLI (recommended)
./vm.sh ubu1              # Create/start VM named ubu1
./vm.sh ubu1 status       # Show state
./vm.sh ubu1 stop         # Graceful shutdown
./vm.sh ubu1 reinstall    # Wipe and reinstall OS
./vm.sh list              # List all VMs

# Legacy individual scripts (still available)
sudo ./setup-ubuntu-vm.sh           # One-time setup
sudo ./start-ubuntu-vm.sh install   # First boot with ISO
```

### VM Network

VMs use a bridge network with NAT to the host's physical interface:

| VM | IP Address | VNC Port | QEMU Monitor |
|----|------------|----------|--------------|
| First | $VM_SUBNET.10 | 5900 | 7100 |
| Second | $VM_SUBNET.11 | 5901 | 7101 |

Gateway: `$VM_SUBNET.1` (host bridge)

### Storage Files

| File | Purpose |
|------|---------|
| `*.rom` | UEFI firmware (shared, read-only) |
| `*.vars` | UEFI variables per VM |
| `*.img` | VM disk images |
| `*.iso` | Installation media |

### QEMU Monitor

Connect via telnet for VM control:
```bash
telnet localhost 7100  # First VM
telnet localhost 7101  # Second VM
```

Commands: `info status`, `system_powerdown`, `quit`

## Directives

- Validate before declaring root cause/solution
- Request user validation for hardware/UI tests - no automated tests exist
- MINIMAL COMPLEXITY: Prefer existing tools over custom code
- Version source of truth: pyproject.toml (mesh), VERSION (repo)
