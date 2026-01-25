# aeo-infra

**v0.1.0** · Infrastructure tools for multi-machine development environments.

## Components

| Directory | Purpose | Technology |
|-----------|---------|------------|
| [`mesh/`](mesh/) | Mesh networking between machines | Python CLI (Headscale + Syncthing) |
| [`vms/`](vms/) | QEMU/KVM virtual machine management | Bash scripts |

## Quick Start

### Mesh Networking

Self-hosted mesh network using Headscale (Tailscale control server) and Syncthing (file sync).

```bash
cd mesh
uv sync
uv run mesh --help

# Server setup (sfspark1)
uv run mesh server setup

# Client setup (other machines)
uv run mesh client setup --server http://sfspark1.local:8080 --key <KEY>

# Status check
uv run mesh status
```

See [`mesh/README.md`](mesh/README.md) for full documentation.

### Virtual Machine Management

ARM64 KVM virtual machines with shared networking on GB10.

```bash
cd vms

# Auto-detect and manage VM
./vm.sh ubu1              # Create/start VM named ubu1
./vm.sh ubu1 status       # Show state
./vm.sh ubu1 stop         # Graceful shutdown
./vm.sh list              # List all VMs
```

See [`vms/README.md`](vms/README.md) for full documentation.

## Architecture Overview

### Mesh Network

```
sfspark1 (GB10) - Headscale Coordination Server
├── headscale serve (port 8080)
├── Tailscale client (localhost:8080)
└── Syncthing (port 8384/22000)
              ↓ WireGuard mesh (encrypted)
office-one (Windows + WSL2) - Tailscale Clients
├── WSL2 Tailscale + Syncthing (8385/22001)
└── Windows Tailscale + Syncthing (8386/22002)
```

### VM Network

```
┌─────────────────────────────────────────────────────┐
│  Host (192.168.50.1)                                │
│  ┌─────────────┐                                    │
│  │   br-vm     │◄─── NAT to enP7s7 ───► Internet   │
│  └──────┬──────┘                                    │
│    ┌────┴────┐                                      │
│ ┌──┴──┐   ┌──┴──┐                                  │
│ │tap0 │   │tap1 │                                  │
│ └──┬──┘   └──┬──┘                                  │
└────┼─────────┼──────────────────────────────────────┘
┌────┴────┐ ┌──┴─────┐
│ Windows │ │ Ubuntu │
│ .50.11  │ │ .50.10 │
└─────────┘ └────────┘
```

## Network Reference

### Mesh Network Ports

| Machine | SSH | Syncthing GUI | Syncthing Sync | Headscale |
|---------|-----|---------------|----------------|-----------|
| sfspark1 | 22 | 8384 | 22000 | 8080 (server) |
| WSL2 | 2222 | 8385 | 22001 | - |
| Windows | 22 | 8386 | 22002 | - |

### VM Access

| VM | VNC Display | VNC Port | WebSocket | QEMU Monitor |
|----|-------------|----------|-----------|--------------|
| Windows | :0 | 5900 | 5700 | 7100 |
| Ubuntu | :1 | 5901 | 5701 | 7101 |

## Requirements

### Mesh Tools
- Python 3.13+
- uv (package manager)

### VM Scripts
- QEMU/KVM
- ARM64 host (GB10)
- UEFI firmware

## License

MIT
