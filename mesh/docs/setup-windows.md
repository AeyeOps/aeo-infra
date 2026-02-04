# Windows Setup Guide

This guide covers connecting Windows machines to the Headscale mesh and
mounting the shared directory at `C:\dev\shared`.

## Prerequisites

- Windows 10/11 (x64 or ARM64)
- Tailscale client installed and connected to the Headscale mesh
- Administrator access (for WinFsp installation)

## Mesh Connectivity

### Install Tailscale

```powershell
winget install tailscale.tailscale
```

Connect to the Headscale coordination server. Get the pre-auth key from the
server admin:

```powershell
tailscale up --login-server http://<headscale-ip>:8080 --authkey <KEY>
```

Verify:

```powershell
tailscale status
```

You should see the other mesh nodes (sfspark1, office-one, etc.) and have a
100.64.x.x address assigned.

## Shared Directory Setup

The mesh shared directory lives on sfspark1 at `/opt/shared`. Windows nodes
access it via rclone mounting over SFTP through the Tailscale tunnel.

### Why rclone SFTP (Not NFS or SMB)

- **Windows NFS client** is NFSv3 only, drive-letter-only, requires registry
  hacks for write access, and does not persist reliably.
- **SMB/Samba** works but requires Samba server configuration on sfspark1,
  separate user management, and has a known performance bug with Tailscale
  (SMB Multichannel routes traffic through the Tailscale interface which
  reports 100Gbps link speed, destroying throughput on same-LAN setups).
- **rclone SFTP** uses existing SSH infrastructure, supports mounting to a
  folder path (not just drive letters), and includes VFS caching for
  performance.

### Install Dependencies

```powershell
# WinFsp (FUSE layer for Windows -- enables rclone mount)
winget install WinFsp.WinFsp

# rclone
winget install Rclone.Rclone
```

### Configure rclone Remote

Ensure you have an SSH key at `C:\Users\<username>\.ssh\id_ed25519` that is
authorized on sfspark1.

```powershell
rclone config create sfspark1 sftp host=100.64.0.1 user=steve key_file=C:\Users\steve\.ssh\id_ed25519 shell_type=unix
```

Verify connectivity:

```powershell
rclone ls sfspark1:/opt/shared/
```

### Mount to C:\dev\shared

The parent directory `C:\dev` must exist. The mount point `C:\dev\shared` must
NOT exist (rclone creates it).

```powershell
# Create parent if needed
mkdir C:\dev

# If C:\dev\shared already exists, move it first
Move-Item -Path C:\dev\shared -Destination C:\dev\shared-backup

# Mount
rclone mount sfspark1:/opt/shared C:\dev\shared --vfs-cache-mode full --dir-cache-time 5s --poll-interval 10s --vfs-cache-poll-interval 5s --volname mesh-shared
```

Mount options:

| Option | Purpose |
|--------|---------|
| `--vfs-cache-mode full` | Full read/write caching for performance |
| `--dir-cache-time 5s` | Directory listing refreshes every 5 seconds |
| `--poll-interval 10s` | Check remote for changes every 10 seconds |
| `--vfs-cache-poll-interval 5s` | VFS cache refresh interval |
| `--volname mesh-shared` | Volume label shown in Explorer |

### Verify

```powershell
# List contents
Get-ChildItem C:\dev\shared

# Write test
Set-Content -Path C:\dev\shared\.write_test -Value "test"
Get-Content C:\dev\shared\.write_test
Remove-Item C:\dev\shared\.write_test
```

### Persist Across Reboots

rclone mount runs in the foreground and stops when the terminal closes. To
persist it, create a Windows Task Scheduler entry:

```powershell
$action = New-ScheduledTaskAction `
    -Execute "rclone.exe" `
    -Argument "mount sfspark1:/opt/shared C:\dev\shared --vfs-cache-mode full --dir-cache-time 5s --poll-interval 10s --vfs-cache-poll-interval 5s --volname mesh-shared"

$trigger = New-ScheduledTaskTrigger -AtLogOn

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit 0 `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName "Mesh Shared Mount" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Mount mesh shared directory from sfspark1 via rclone SFTP"
```

To remove:

```powershell
Unregister-ScheduledTask -TaskName "Mesh Shared Mount" -Confirm:$false
```

### Manual Start/Stop

```powershell
# Start (runs in foreground -- use a dedicated terminal or Task Scheduler)
rclone mount sfspark1:/opt/shared C:\dev\shared --vfs-cache-mode full --dir-cache-time 5s --poll-interval 10s --vfs-cache-poll-interval 5s --volname mesh-shared

# Stop (from another terminal)
Get-Process rclone | Stop-Process -Force
```

## Cache Behavior

rclone with `--vfs-cache-mode full` maintains a local cache of files. This
means:

- **Reads** are fast after the first access (served from cache)
- **Writes from Windows** appear on the remote immediately
- **External writes** (from other mesh nodes via NFS) take up to
  `--dir-cache-time` (5s) to appear in directory listings, and cached file
  contents refresh on `--poll-interval` (10s)
- The cache lives at `%APPDATA%\rclone\vfs\sfspark1` and can be cleared with
  `rclone cache clear sfspark1:`

For use cases requiring instant visibility of external writes, reduce
`--dir-cache-time` to `1s` at the cost of more SFTP round trips.

## Troubleshooting

### Mount fails with "mount helper error"

WinFsp is not installed or not in PATH. Reinstall:

```powershell
winget install WinFsp.WinFsp --force
```

Reboot may be required after WinFsp installation.

### "C:\dev\shared already exists"

rclone cannot mount to an existing directory. Move or rename it first:

```powershell
Move-Item -Path C:\dev\shared -Destination C:\dev\shared-backup
```

### Permission denied on SSH

Verify the SSH key works:

```powershell
ssh -i C:\Users\steve\.ssh\id_ed25519 steve@100.64.0.1 "echo ok"
```

If this fails, ensure the public key is in `~/.ssh/authorized_keys` on
sfspark1.

### Slow directory listings

Increase `--dir-cache-time` for less frequent remote checks:

```powershell
--dir-cache-time 30s
```

### SMB Multichannel warning

If you also use SMB shares on the same network and notice performance
degradation, Tailscale's 100Gbps reported link speed confuses Windows SMB
Multichannel. Fix:

```powershell
Get-NetAdapter | Where {$_.InterfaceAlias -eq "Tailscale"} | Set-NetIPInterface -InterfaceMetric 500
```

## Mesh Topology Reference

```
Node                    Tailscale IP    OS        Shared Directory Access
----                    ------------    --        ----------------------
sfspark1                100.64.0.1      Linux     Local directory (NFS server)
office-one (WSL2)       100.64.0.3      Linux     NFSv4 mount
office-one (Windows)    100.64.0.4      Windows   rclone SFTP mount at C:\dev\shared
```

All traffic between nodes is encrypted by WireGuard (Tailscale/Headscale).
SFTP adds a second encryption layer over SSH.
