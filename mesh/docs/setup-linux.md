# Linux Setup Guide

This guide covers setting up the mesh network on native Linux (Ubuntu, Debian, Fedora, etc.).

## Prerequisites

- Linux x64 or ARM64
- Python 3.13+
- sudo access
- Network access to the coordination server

## Quick Start (Client)

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

## Server Setup

If this machine is the coordination server:

```bash
# 1. Run wizard and select "server" role
uv run mesh init

# 2. Setup installs Headscale and starts the service
uv run mesh server setup

# 3. Generate a key for clients
uv run mesh server keygen

# 4. (Optional) Enable auto-discovery for LAN clients
uv run mesh server setup --advertise
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

## Troubleshooting

### Tailscale not connecting

1. Check if the server is reachable:
   ```bash
   curl http://server:8080/health
   ```

2. Verify Tailscale service:
   ```bash
   sudo systemctl status tailscaled
   ```

3. Check logs:
   ```bash
   journalctl -u tailscaled -f
   ```

### Syncthing not finding peers

1. Ensure Syncthing is running:
   ```bash
   systemctl --user status syncthing
   ```

2. Exchange device IDs:
   ```bash
   uv run mesh peer
   ```

### Auto-discovery not working

mDNS requires UDP port 5353 to be open. Check firewall:

```bash
sudo ufw allow 5353/udp
```

Or temporarily disable firewall for testing:

```bash
sudo ufw disable
```

## Environment Variables

Configure in `.env` or export directly:

| Variable | Description | Example |
|----------|-------------|---------|
| `MESH_SERVER_HOSTNAMES` | Server hostname(s) | `myserver,myserver.local` |
| `MESH_WSL2_HOSTNAMES` | WSL2 client hostnames | `myclient` |
| `MESH_DEFAULT_USER` | Default SSH user | `ubuntu` |
| `MESH_SHARED_FOLDER_LINUX` | Shared folder path | `/home/shared` |
