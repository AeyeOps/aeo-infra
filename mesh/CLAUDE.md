# Mesh Network Share Tools

This directory contains scripts for managing a self-hosted mesh network between sfspark1 (NVIDIA GB10), office-one (WSL2), and Windows using **Headscale** (self-hosted Tailscale control server) + **Syncthing**.

**No external dependencies on tailscale.com** - all coordination happens through the Headscale server running on sfspark1.

## Architecture

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

**Key benefits:**
- **Fully self-hosted** - No external accounts or services required
- **No single point of failure** - Syncthing peers can sync without coordinator once connected
- **Works beyond LAN** - Tailscale handles NAT traversal for remote access
- **True bidirectional sync** - Syncthing is peer-to-peer, not client-server
- **Zero-admin after setup** - Mesh auto-heals, Syncthing auto-reconnects

## Network Configuration

| Machine | Role | SSH Port | Syncthing GUI | Syncthing Sync | Headscale |
|---------|------|----------|---------------|----------------|-----------|
| sfspark1 | Server + Peer | 22 | 8384 | 22000 | 8080 (server) |
| office-one (WSL2) | Peer | 2222 | 8385 | 22001 | - |
| Windows | Peer | 22 | 8386 | 22002 | - |

**Shared Folder Paths:**
- sfspark1: `/opt/shared`
- WSL2: `/opt/shared`
- Windows: `C:\shared`

## Scripts

| Script | Purpose |
|--------|---------|
| `setup-headscale-server.sh` | Install Headscale server on sfspark1 |
| `setup-headscale-server.sh --keygen` | Generate pre-auth key for clients |
| `setup-headscale-server.sh --status` | Show Headscale server status |
| `setup-mesh.sh --server URL --key KEY` | Install client and join mesh |
| `setup-mesh.sh --status` | Show client connection status |
| `setup-mesh.ps1` | Windows companion - firewall, services |
| `mesh-status.sh` | Quick health check |
| `mesh-status.sh --verbose` | Detailed diagnostics with fixes |
| `add-syncthing-peer.sh` | Exchange device IDs and share folders |
| `lib/mesh-common.sh` | Shared helper functions |

## Quick Start

### 1. Set Up Headscale Server (sfspark1)

```bash
# On sfspark1 (requires sudo)
sudo ./setup-headscale-server.sh

# Note the pre-auth key displayed at the end
# Or generate a new one:
sudo ./setup-headscale-server.sh --keygen
```

### 2. Join Clients to Mesh

```bash
# On WSL2 (get KEY from step 1)
./setup-mesh.sh --server http://sfspark1.local:8080 --key YOUR_KEY

# On Windows (elevated PowerShell)
.\setup-mesh.ps1 -All -HeadscaleServer "http://sfspark1.local:8080" -AuthKey "YOUR_KEY"
```

### 3. Exchange Syncthing Device IDs

```bash
# On each machine
./add-syncthing-peer.sh
# Enter the other machine's device ID when prompted
```

### 4. Verify Setup

```bash
./mesh-status.sh
```

## Headscale Administration

### Server Commands (run on sfspark1)

```bash
# Show status
sudo ./setup-headscale-server.sh --status

# Generate new pre-auth key
sudo ./setup-headscale-server.sh --keygen

# List connected nodes
sudo headscale nodes list

# List users
sudo headscale users list
```

### Service Management

```bash
# Start/stop/restart
sudo systemctl start headscale
sudo systemctl stop headscale
sudo systemctl restart headscale

# View logs
sudo journalctl -u headscale -f
```

## Tailscale Client Commands

```bash
# Check status
tailscale status

# Ping a peer
tailscale ping sfspark1

# Get your Tailscale IP
tailscale ip -4

# Reconnect (if disconnected)
sudo tailscale up --login-server=http://sfspark1.local:8080 --authkey=KEY
```

## Monitoring

### Syncthing Web UI

| Node | URL |
|------|-----|
| sfspark1 | http://localhost:8384 |
| WSL2 | http://localhost:8385 |
| Windows | http://localhost:8386 |

### Health Check

```bash
./mesh-status.sh           # Quick check
./mesh-status.sh --verbose # Detailed diagnostics
```

## SSH Access

SSH config is deployed to `~/.ssh/config`:

```
Host sfspark1
    HostName sfspark1.local
    User steve

Host office-one
    HostName office-one.local
    Port 2222
    User steve

Host windows
    HostName office-one.local
    Port 22
    User steve
```

**From any machine:**
```bash
ssh sfspark1      # Connect to sfspark1
ssh office-one    # Connect to WSL2
ssh windows       # Connect to Windows
```

## Conflict Handling

Syncthing preserves both versions on conflict:
```
file.txt                                    # Current version
file.txt.sync-conflict-20240115-123456.txt  # Conflicting version
```

**Resolution:** Review both versions, keep the correct one, delete the conflict file.

## Troubleshooting

### Quick Diagnostics

```bash
./mesh-status.sh           # Quick health check
./mesh-status.sh --verbose # Detailed diagnostics with fixes
```

### Common Issues

**Headscale server not running (sfspark1):**
```bash
sudo systemctl status headscale
sudo systemctl start headscale
sudo ./setup-headscale-server.sh --status
```

**Tailscale client not connecting:**
1. Verify Headscale server is running on sfspark1
2. Check server is reachable: `curl http://sfspark1.local:8080/health`
3. Get a new pre-auth key: `sudo ./setup-headscale-server.sh --keygen`
4. Re-join: `./setup-mesh.sh --join --server http://sfspark1.local:8080 --key NEW_KEY`

**WSL2 SSH not accessible:**
1. Verify systemd is enabled (`/etc/wsl.conf`: `[boot] systemd=true`)
2. Check SSH is on port 2222: `grep Port /etc/ssh/sshd_config`
3. Verify Windows firewall rule exists (run `setup-mesh.ps1 -Firewall`)

**Syncthing devices not connecting:**
1. Verify both devices have each other's device ID
2. Check firewall allows sync ports (22000-22002)
3. Verify folder is shared with the device in Syncthing GUI

**Files not syncing:**
1. Check `.stignore` patterns aren't blocking files
2. Look for conflict files (`*.sync-conflict-*`)
3. Check folder permissions: `ls -la /opt/shared`

## Legacy Scripts

Previous SSHFS-based scripts are archived in `legacy/` for rollback:

| Legacy Script | Replaced By |
|---------------|-------------|
| `setup-ssh-server.sh` | `setup-mesh.sh` |
| `setup-sshfs-client.sh` | `setup-mesh.sh` (Syncthing) |
| `setup-openssh-windows.sh` | `setup-mesh.sh` + `setup-mesh.ps1` |
| `setup-sshfs-windows.sh` | `setup-mesh.sh` (no SSHFS-Win needed) |
| `reconnect.sh` | Syncthing auto-reconnects |
