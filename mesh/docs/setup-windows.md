# Windows Setup Guide

This guide covers setting up the mesh network on Windows (native, not WSL2).

## Prerequisites

- Windows 10/11 (x64 or ARM64)
- Python 3.13+ (via winget or python.org)
- Administrator access
- Network access to the coordination server

## Quick Start

```powershell
# 1. Install prerequisites manually
winget install tailscale.tailscale
winget install Syncthing.Syncthing

# 2. Clone and install mesh tools
git clone <repo-url>
cd aeo-infra\mesh
uv sync

# 3. Run setup wizard
uv run mesh init

# 4. Join the mesh (get KEY from server admin)
uv run mesh client setup --server http://server:8080 --key <KEY>

# 5. Verify connection
uv run mesh status
```

## Important: Manual Installation Required

Unlike Linux/WSL2, Windows requires **manual installation** of Tailscale and Syncthing before running `mesh client setup`. The mesh CLI cannot auto-install these on Windows.

### Install Tailscale

Option 1 - winget (recommended):
```powershell
winget install tailscale.tailscale
```

Option 2 - Download from https://tailscale.com/download/windows

### Install Syncthing

Option 1 - winget (recommended):
```powershell
winget install Syncthing.Syncthing
```

Option 2 - Download from https://syncthing.net/downloads/

## Client Setup

### With Auto-Discovery

If the server is on the same network and advertising via mDNS:

```powershell
uv run mesh client setup --discover --key <KEY>
```

### With Manual Server URL

```powershell
uv run mesh client setup --server http://server.local:8080 --key <KEY>
```

## Verification

```powershell
# Check mesh network status
uv run mesh status

# Should show:
#   Tailscale: connected
#   Syncthing: running
#   Mesh IP: 100.64.x.x
```

## Troubleshooting

### Tailscale not connecting

1. Open Tailscale from system tray
2. Check connection status
3. Try re-authenticating with the pre-auth key

### Auto-discovery not working

mDNS on Windows may be blocked by firewall. Try:

1. Allow mDNS through Windows Firewall
2. Or specify server URL directly: `--server http://server:8080`

### Hyper-V network issues

If running in Hyper-V VM, UDP multicast may not work correctly. Use explicit `--server` URL instead of `--discover`.

### Syncthing not starting

Check if Syncthing service is running:

```powershell
Get-Service syncthing
```

Start manually if needed:

```powershell
Start-Service syncthing
```

## Environment Variables

Configure in `.env` file in the project root:

| Variable | Description | Example |
|----------|-------------|---------|
| `MESH_WINDOWS_HOSTNAMES` | This machine's hostname | `DESKTOP-ABC123` |
| `MESH_SERVER_URL` | Server URL for rejoining | `http://server:8080` |
| `MESH_SHARED_FOLDER_WINDOWS` | Shared folder path | `C:\Shared` |

## ARM64 Notes

Windows on ARM64 (e.g., Surface Pro X, Snapdragon laptops) is supported. Both Tailscale and Syncthing have ARM64 builds available.
