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

## Windows VM with Shared Networking

The Windows VM can now use the same bridge network:

```bash
# Stop current Windows VM first (however it was started)
# Then start with shared networking:
sudo ./start-windows-vm.sh

# Stop
sudo ./stop-windows-vm.sh
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
