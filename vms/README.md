# VM Management Scripts

ARM64 KVM virtual machines with shared networking on GB10.

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `setup-vm-network.sh` | Creates bridge + TAPs (run at boot or before VMs) |
| `setup-ubuntu-vm.sh` | Downloads ISO, creates disk, installs UEFI firmware |
| `start-ubuntu-vm.sh` | Start Ubuntu VM (`install` arg for first boot) |
| `stop-ubuntu-vm.sh` | Graceful Ubuntu shutdown |
| `start-windows-vm.sh` | Start Windows VM with shared networking |
| `stop-windows-vm.sh` | Graceful Windows shutdown |
| `vm-network.service` | Systemd service for boot-time network setup |

## Quick Start

```bash
# Unified CLI (recommended)
./vm.sh ubu1              # Create/start VM named ubu1
./vm.sh ubu1 status       # Show state
./vm.sh ubu1 stop         # Graceful shutdown
./vm.sh list              # List all VMs
```

### Manual Setup (legacy scripts)

```bash
# 1. Setup (creates /storage if needed, downloads ISO, installs UEFI)
sudo ./setup-ubuntu-vm.sh

# 2. Start with installation ISO
sudo ./start-ubuntu-vm.sh install

# 3. Connect via VNC: localhost:1 (port 5901) and install Ubuntu

# 4. After installation, boot normally
sudo ./start-ubuntu-vm.sh

# 5. Stop
sudo ./stop-ubuntu-vm.sh
```

## Windows VMs (Golden Image + Overlay)

Windows VMs use a golden image pattern: build once, spin up disposable instances instantly via copy-on-write overlays. Managed by `winvm.sh`.

### Quick Start

```bash
# One-time: build the golden image (interactive Windows install via VNC)
sudo ./winvm.sh golden build

# Spin up a Windows VM (instant overlay creation)
sudo ./winvm.sh start meshtest

# Use it
./winvm.sh ssh meshtest
./winvm.sh exec meshtest "hostname"

# Tear down (overlay deleted, golden image untouched)
sudo ./winvm.sh destroy meshtest
```

### Commands

| Command | Description |
|---------|-------------|
| `winvm.sh start <name>` | Create overlay + boot from golden image |
| `winvm.sh stop <name>` | Graceful ACPI shutdown |
| `winvm.sh destroy <name>` | Stop + delete overlay files |
| `winvm.sh ssh <name>` | Connect via SSH |
| `winvm.sh exec <name> <cmd>` | Run command on VM |
| `winvm.sh status <name>` | Check VM state |
| `winvm.sh list` | List running Windows VMs |
| `winvm.sh golden build` | Build golden image (one-time) |
| `winvm.sh golden status` | Check golden image |
| `winvm.sh golden destroy` | Remove golden image |

### Golden Image

Pre-installed in the golden image:
- Windows 11 ARM64 with OpenSSH Server
- `testuser` account (password: `TestPass123!`, admin)
- Static IP `192.168.50.200/24`, gateway `192.168.50.1`
- Tailscale client

See `golden/README.md` for build details.

### Legacy Scripts

The legacy single-instance scripts are still available:

```bash
sudo ./start-windows-vm.sh   # Start with shared networking
sudo ./stop-windows-vm.sh    # Graceful shutdown
```

## Network Architecture

```
┌─────────────────────────────────────────────────────┐
│  Host (192.168.50.1)                                │
│  ┌─────────────┐                                    │
│  │   br-vm     │◄─── NAT to enP7s7 ───► Internet   │
│  └──────┬──────┘                                    │
│         │                                           │
│    ┌────┴────┐                                      │
│    │         │                                      │
│ ┌──┴──┐   ┌──┴──┐                                  │
│ │qemu │   │tap- │                                  │
│ │     │   │ubuntu│                                  │
│ └──┬──┘   └──┬──┘                                  │
└────┼─────────┼──────────────────────────────────────┘
     │         │
┌────┴────┐ ┌──┴─────┐
│ Windows │ │ Ubuntu │
│ .50.11  │ │ .50.10 │
└─────────┘ └────────┘
```

Configure in each VM:
- Gateway: `192.168.50.1`
- Windows: `192.168.50.11/24`
- Ubuntu: `192.168.50.10/24`
- DNS: `8.8.8.8` or your preferred

## Boot-time Network Setup

Install the systemd service for automatic network setup at boot:

```bash
sudo cp vm-network.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable vm-network.service
```

## VNC Access

| VM | Display | Port | WebSocket |
|----|---------|------|-----------|
| Windows | :0 | 5900 | 5700 |
| Ubuntu | :1 | 5901 | 5701 |

## QEMU Monitor

Connect via telnet for VM control:

```bash
telnet localhost 7100  # Windows
telnet localhost 7101  # Ubuntu
```

Commands: `info status`, `system_powerdown`, `quit`

## Files in /storage/

| File | Purpose |
|------|---------|
| `windows.rom` | UEFI firmware (shared, read-only) |
| `windows.vars` | Windows UEFI variables |
| `data.img` | Windows disk |
| `ubuntu.img` | Ubuntu disk (64GB) |
| `ubuntu.vars` | Ubuntu UEFI variables |
| `*.iso` | Installation media |
