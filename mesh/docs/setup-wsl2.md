# WSL2 Setup Guide

This guide covers setting up the mesh network in Windows Subsystem for Linux 2 (WSL2).

## Prerequisites

- Windows 10/11 with WSL2 enabled
- Ubuntu or Debian distribution in WSL2
- Python 3.13+
- Network access to the coordination server

## Quick Start

```bash
# 1. Clone and install
git clone <repo-url> && cd aeo-infra/mesh
uv sync

# 2. Run setup wizard
uv run mesh init

# 3. Join the mesh (get KEY from server admin)
uv run mesh client setup --server http://server:8080 --key <KEY>

# 4. Verify connection
uv run mesh status

# 5. Add Syncthing peers
uv run mesh peer
```

## Client Setup

### With Auto-Discovery

If the server is on the same network and advertising via mDNS:

```bash
uv run mesh client setup --discover --key <KEY>
```

### With Manual Server URL

```bash
uv run mesh client setup --server http://server.local:8080 --key <KEY>
```

## Verification

```bash
# Check mesh network status
uv run mesh status

# Should show:
#   Tailscale: connected
#   Syncthing: running
#   Mesh IP: 100.64.x.x
```

## WSL2-Specific Considerations

### Network Mode

WSL2 uses NAT networking by default, which means:
- Your WSL2 instance has a different IP than your Windows host
- mDNS discovery works, but may require Windows firewall rules

### Shared Hostname

WSL2 shares its hostname with Windows. The mesh tools detect WSL2 vs Windows automatically based on `/proc/version`.

If you run mesh on both WSL2 and Windows on the same machine, configure both in `.env`:

```bash
MESH_WSL2_HOSTNAMES=myhostname
MESH_WINDOWS_HOSTNAMES=myhostname
```

### Tailscale in WSL2

Tailscale runs natively in WSL2 using `tailscaled` daemon. The mesh setup handles this automatically.

Note: Running Tailscale in both WSL2 AND Windows simultaneously requires coordination. Generally, choose one or the other for mesh connectivity.

## Troubleshooting

### Tailscale not connecting

1. Check if tailscaled is running:
   ```bash
   sudo systemctl status tailscaled
   ```

2. Restart tailscaled:
   ```bash
   sudo systemctl restart tailscaled
   ```

3. Check Windows firewall isn't blocking WSL2 traffic

### DNS resolution issues

WSL2 may have DNS issues. Try:

```bash
# Edit /etc/resolv.conf
sudo sh -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
```

Or configure WSL2 to not auto-generate resolv.conf in `/etc/wsl.conf`:

```ini
[network]
generateResolvConf = false
```

### Auto-discovery not working

mDNS in WSL2 depends on Windows firewall settings. Ensure UDP port 5353 is allowed:

1. Open Windows Defender Firewall
2. Advanced Settings > Inbound Rules
3. New Rule > Port > UDP 5353 > Allow

Or use explicit server URL:

```bash
uv run mesh client setup --server http://server:8080 --key <KEY>
```

### Syncthing conflicts with Windows Syncthing

If you have Syncthing running on Windows too, ensure they use different ports or only run one at a time.

## Environment Variables

Configure in `.env` file in the project root:

| Variable | Description | Example |
|----------|-------------|---------|
| `MESH_WSL2_HOSTNAMES` | This machine's hostname | `myhostname` |
| `MESH_SERVER_URL` | Server URL for rejoining | `http://server:8080` |
| `MESH_SHARED_FOLDER_LINUX` | Shared folder path | `/mnt/c/Shared` |

## Accessing Windows Files

WSL2 can access Windows drives at `/mnt/c/`, `/mnt/d/`, etc. Consider setting your shared folder to a Windows path for cross-environment access:

```bash
MESH_SHARED_FOLDER_LINUX=/mnt/c/Shared
```
