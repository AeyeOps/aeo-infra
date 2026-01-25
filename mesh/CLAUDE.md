# Mesh Network Share Tools

This directory contains tools for managing a self-hosted mesh network using **Headscale** (self-hosted Tailscale control server) + **Syncthing**.

**No external dependencies on tailscale.com** - all coordination happens through your own Headscale server.

## Architecture

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

**Key benefits:**
- **Fully self-hosted** - No external accounts or services required
- **No single point of failure** - Syncthing peers can sync without coordinator once connected
- **Works beyond LAN** - Tailscale handles NAT traversal for remote access
- **True bidirectional sync** - Syncthing is peer-to-peer, not client-server
- **Zero-admin after setup** - Mesh auto-heals, Syncthing auto-reconnects

## Configuration

Set these environment variables (or in `../.env`):
- `MESH_DEFAULT_USER` - Default SSH username
- `MESH_SHARED_FOLDER_LINUX` - Linux shared folder (default: `/opt/shared`)
- `MESH_SHARED_FOLDER_WINDOWS` - Windows shared folder (default: `C:\shared`)

## Network Configuration

| Role | SSH Port | Syncthing GUI | Syncthing Sync | Headscale |
|------|----------|---------------|----------------|-----------|
| Server | 22 | 8384 | 22000 | 8080 |
| WSL2 | 2222 | 8385 | 22001 | - |
| Windows | 22 | 8386 | 22002 | - |

## Python CLI

The primary interface is the Python CLI:

```bash
# Server management
uv run mesh server setup
uv run mesh server keygen
uv run mesh server status

# Client setup
uv run mesh client setup --server http://<server>:8080 --key <KEY>
uv run mesh client join --key <KEY>

# Status
uv run mesh status
uv run mesh status --verbose

# Peer exchange
uv run mesh peer
```

## Headscale Administration

### Service Management

```bash
# Start/stop/restart
sudo systemctl start headscale
sudo systemctl stop headscale
sudo systemctl restart headscale

# View logs
sudo journalctl -u headscale -f

# List connected nodes
sudo headscale nodes list
```

## Tailscale Client Commands

```bash
# Check status
tailscale status

# Ping a peer
tailscale ping <hostname>

# Get your Tailscale IP
tailscale ip -4

# Reconnect (if disconnected)
sudo tailscale up --login-server=http://<server>:8080 --authkey=KEY
```

## Monitoring

### Syncthing Web UI

| Role | URL |
|------|-----|
| Server | http://localhost:8384 |
| WSL2 | http://localhost:8385 |
| Windows | http://localhost:8386 |

## Conflict Handling

Syncthing preserves both versions on conflict:
```
file.txt                                    # Current version
file.txt.sync-conflict-20240115-123456.txt  # Conflicting version
```

**Resolution:** Review both versions, keep the correct one, delete the conflict file.

## Troubleshooting

### Common Issues

**Headscale server not running:**
```bash
sudo systemctl status headscale
sudo systemctl start headscale
```

**Tailscale client not connecting:**
1. Verify Headscale server is running
2. Check server is reachable: `curl http://<server>:8080/health`
3. Get a new pre-auth key: `uv run mesh server keygen`
4. Re-join: `uv run mesh client join --key NEW_KEY`

**WSL2 SSH not accessible:**
1. Verify systemd is enabled (`/etc/wsl.conf`: `[boot] systemd=true`)
2. Check SSH is on port 2222: `grep Port /etc/ssh/sshd_config`
3. Verify Windows firewall rule exists

**Syncthing devices not connecting:**
1. Verify both devices have each other's device ID
2. Check firewall allows sync ports (22000-22002)
3. Verify folder is shared with the device in Syncthing GUI

**Files not syncing:**
1. Check `.stignore` patterns aren't blocking files
2. Look for conflict files (`*.sync-conflict-*`)
3. Check folder permissions

## Archive

Previous shell scripts are archived in `archive/` for reference:
- `archive/shell/` - Original bash scripts (replaced by Python CLI)
- `archive/sshfs/` - Old SSHFS-based scripts (replaced by Syncthing)
- `archive/specs/` - Original specifications
