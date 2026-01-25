# Port Reference

Complete list of port assignments used in the MeSH network.

## SSH Ports

| Host | Port | Protocol | Description |
|------|------|----------|-------------|
| sfspark1 | 22 | SSH | Headscale server SSH |
| office-one (Windows) | 22 | SSH | Windows OpenSSH Server |
| office-one (WSL) | 2222 | SSH | WSL2 SSH (avoids Windows conflict) |
| windows-vm (Docker) | 2222 | SSH | Test VM mapped from container |

### Why WSL Uses Port 2222

Windows and WSL2 share the same network namespace. Both can run SSH servers, but they can't share port 22. The convention:
- **Port 22**: Windows OpenSSH Server
- **Port 2222**: WSL2 SSH

This allows both to be reachable from the same external IP.

### SSH Config Example

```
Host sfspark1
    HostName sfspark1.local
    Port 22
    User steve

Host windows
    HostName office-one.local
    Port 22
    User steve

Host wsl
    HostName office-one.local
    Port 2222
    User steve

Host windows-vm
    HostName localhost
    Port 2222
    User Docker
```

## Headscale Ports

| Host | Port | Protocol | Description |
|------|------|----------|-------------|
| sfspark1 | 8080 | HTTP | Headscale coordination server |

### Headscale URL

All Tailscale clients connect to:
```
http://sfspark1.local:8080
```

For Docker environments that can't resolve mDNS:
```
http://10.0.0.56:8080
```

## Tailscale/WireGuard Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 41641 | UDP | Default WireGuard port (Tailscale) |

Tailscale handles NAT traversal automatically. Port 41641 is used when direct connections are possible.

### Tailscale IP Range

The mesh uses the `100.64.0.0/10` CGNAT range:

| Node | Tailscale IP |
|------|--------------|
| sfspark1 | 100.64.0.1 |
| windows | 100.64.0.2 |
| wsl | 100.64.0.3 |

These IPs are assigned by Headscale and remain stable.

## Syncthing Ports

| Host | GUI Port | Sync Port | Description |
|------|----------|-----------|-------------|
| sfspark1 | 8384 | 22000 | Primary Syncthing instance |
| WSL2 | 8385 | 22001 | WSL Syncthing |
| Windows | 8386 | 22002 | Windows Syncthing |

### Port Conflicts

Each Syncthing instance needs unique ports because:
- GUI ports must be distinct for web access
- Sync ports must be distinct for peer discovery

### Syncthing Web UI Access

| Instance | URL |
|----------|-----|
| sfspark1 | http://localhost:8384 |
| WSL | http://localhost:8385 |
| Windows | http://localhost:8386 |

## Firewall Rules

### Windows Firewall

Required rules for Windows hosts:

```powershell
# Allow SSH to WSL
New-NetFirewallRule -DisplayName "WSL SSH" `
    -Direction Inbound -LocalPort 2222 `
    -Protocol TCP -Action Allow

# Allow Syncthing (if running on Windows)
New-NetFirewallRule -DisplayName "Syncthing Sync" `
    -Direction Inbound -LocalPort 22002 `
    -Protocol TCP -Action Allow
```

### Linux Firewall (ufw)

If using ufw on Linux hosts:

```bash
# Allow SSH
sudo ufw allow 22/tcp
sudo ufw allow 2222/tcp  # WSL

# Allow Headscale (server only)
sudo ufw allow 8080/tcp

# Allow Syncthing
sudo ufw allow 22000/tcp
sudo ufw allow 8384/tcp  # GUI (optional, local only)
```

## Port Troubleshooting

### Check if Port is Open

```bash
# From another machine
nc -zv office-one.local 22
nc -zv office-one.local 2222
```

### Check What's Listening

```bash
# Linux
sudo ss -tlnp | grep :22
sudo ss -tlnp | grep :2222

# Windows PowerShell
Get-NetTCPConnection -LocalPort 22 -State Listen
Get-NetTCPConnection -LocalPort 2222 -State Listen
```

### Test Tailscale Port

```bash
# Check if Tailscale is using direct connection
tailscale ping office-one

# Output shows connection path:
# "via 10.0.0.45:41641" = direct connection
# "via DERP" = relayed connection
```

## Docker Port Mappings

For Docker-based Windows VMs:

```yaml
ports:
  - "2222:22"    # SSH
  - "3389:3389"  # RDP
  - "8006:8006"  # noVNC
```

Access:
- SSH: `ssh Docker@localhost -p 2222`
- RDP: `localhost:3389`
- noVNC: `http://localhost:8006`

## Summary Table

| Service | Default Port | Protocol | Notes |
|---------|-------------|----------|-------|
| SSH (standard) | 22 | TCP | Windows, sfspark1 |
| SSH (WSL) | 2222 | TCP | Avoids conflict |
| Headscale | 8080 | HTTP | Coordination server |
| WireGuard | 41641 | UDP | Tailscale connections |
| Syncthing GUI | 8384-8386 | HTTP | Per-instance |
| Syncthing Sync | 22000-22002 | TCP | Per-instance |
| RDP | 3389 | TCP | Windows remote |
| noVNC | 8006 | HTTP | Docker VM console |
