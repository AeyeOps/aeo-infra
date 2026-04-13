# aeo-infra

**v0.2.0** · Infrastructure tools for multi-machine development environments.

## Components

| Directory | Purpose | Technology |
|-----------|---------|------------|
| [`mesh/`](mesh/) | Mesh networking between machines | Python CLI (Headscale + Syncthing) |
| [`vms/`](vms/) | QEMU/KVM virtual machine management | Bash scripts |

> **Note:** The vLLM deployment project has moved to its own repo: [steveant/aeo-vllm-gb10](https://github.com/steveant/aeo-vllm-gb10)

## Configuration

Copy `.env.example` to `.env` and customize for your environment:

```bash
cp .env.example .env
# Edit .env with your hostnames, IPs, and username
```

## Quick Start

### Mesh Networking

Self-hosted mesh network using Headscale (Tailscale control server) and Syncthing (file sync).

```bash
cd mesh
uv sync
uv run mesh --help

# Server setup (on your coordination server)
uv run mesh server setup

# Client setup (other machines)
uv run mesh client setup --server http://<server>:8080 --key <KEY>

# Status check
uv run mesh status
```

See [`mesh/README.md`](mesh/README.md) for full documentation.

### Virtual Machine Management

ARM64 KVM virtual machines with shared networking.

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
Server - Headscale Coordination Server
├── headscale serve (port 8080)
├── Tailscale client (localhost:8080)
└── Syncthing (port 8384/22000)
              ↓ WireGuard mesh (encrypted)
Clients - Tailscale Clients
├── Linux/WSL Tailscale + Syncthing (8385/22001)
└── Windows Tailscale + Syncthing (8386/22002)
```

### VM Network

```
┌─────────────────────────────────────────────────────┐
│  Host (192.168.50.1)                                │
│  ┌─────────────┐                                    │
│  │   br-vm     │◄─── NAT to eth0 ───► Internet     │
│  └──────┬──────┘                                    │
│    ┌────┴────┐                                      │
│ ┌──┴──┐   ┌──┴──┐                                  │
│ │tap0 │   │tap1 │                                  │
│ └──┬──┘   └──┬──┘                                  │
└────┼─────────┼──────────────────────────────────────┘
┌────┴────┐ ┌──┴─────┐
│  VM 1   │ │  VM 2  │
│ .50.10  │ │ .50.11 │
└─────────┘ └────────┘
```

## Network Reference

### Mesh Network Ports

| Role | SSH | Syncthing GUI | Syncthing Sync | Headscale |
|------|-----|---------------|----------------|-----------|
| Server | 22 | 8384 | 22000 | 8080 |
| WSL2 | 2222 | 8385 | 22001 | - |
| Windows | 22 | 8386 | 22002 | - |

### VM Access

| VM | VNC Display | VNC Port | WebSocket | QEMU Monitor |
|----|-------------|----------|-----------|--------------|
| First | :0 | 5900 | 5700 | 7100 |
| Second | :1 | 5901 | 5701 | 7101 |

## Requirements

### Mesh Tools
- Python 3.13+
- uv (package manager)

### VM Scripts
- QEMU/KVM
- ARM64 or x86_64 host
- UEFI firmware

## License

MIT
