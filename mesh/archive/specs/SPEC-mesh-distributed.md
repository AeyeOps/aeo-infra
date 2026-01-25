# Secure Mesh Network + Distributed Filesystem Specification

## Overview

This document specifies a replacement for the current SSHFS-based `/opt/shared` architecture with:
1. **Mesh VPN** - Every machine can reach every other machine by name
2. **Distributed Filesystem** - `/opt/shared` is replicated across all nodes with no single owner

**Target Environment:**
| Machine | OS | Role | Notes |
|---------|-----|------|-------|
| sfspark1 | Ubuntu 24.04 ARM64 (NVIDIA GB10) | Peer node | SSH :22 |
| office-one (WSL2) | WSL2 Ubuntu 22.04 | Peer node | SSH :2222, shares Tailscale IP with Windows |
| windows | Windows 11 (host of office-one) | Peer node | SSH :22, MSYS2/zsh shell |

**Design Principles:**
- Open-source tools only
- Single setup script detects OS and configures appropriately
- No single point of failure
- Zero-admin after initial setup
- Works beyond LAN (internet-capable)

---

## Architecture Comparison

### Current (Centralized SSHFS)
```
sfspark1 ──────── OWNS /opt/shared (physical storage)
    ↑
    ├── office-one ─── mounts via SSHFS
    └── windows ────── mounts via SSHFS-Win

Single point of failure: sfspark1
```

### Proposed (Mesh + Distributed)
```
┌─────────────────────────────────────────────────────┐
│              Tailscale Mesh VPN                     │
│                                                     │
│  sfspark1 ←────────────→ windows + WSL2            │
│  (100.x.x.1)              (100.x.x.2)              │
│                           ├─ Windows SSH :22       │
│                           └─ WSL2 SSH :2222        │
│                                                     │
│  MagicDNS: ssh sfspark1 / ssh windows              │
└─────────────────────────────────────────────────────┘
                        ↓
┌─────────────────────────────────────────────────────┐
│              Syncthing Cluster (3 instances)        │
│                                                     │
│  sfspark1:/opt/shared ←──────→ WSL2:/opt/shared    │
│           ↖                      ↗  (ext4)         │
│            ←→ Windows:C:\shared ←→                 │
│                   (NTFS)                           │
│                                                     │
│  All nodes are equal peers. Any can go offline.    │
│  Changes sync automatically when reconnected.      │
│                                                     │
│  Note: WSL2 and Windows run separate Syncthing     │
│  instances on different filesystems - no conflict. │
└─────────────────────────────────────────────────────┘

No single point of failure. True distributed ownership.
```

---

## Component Selection

### Mesh VPN: Tailscale

**Why Tailscale:**
- Zero-config setup (install → authenticate → connected)
- MagicDNS provides automatic hostname resolution (`ssh sfspark1` just works)
- Works across NAT, firewalls, and the internet
- Free tier: 100 devices, 3 users (sufficient for personal use)
- ARM64 native support (tested on GB10/Grace Blackwell)
- WSL2 support: Install on Windows host, WSL2 inherits connectivity
- Peer-to-peer encrypted (WireGuard protocol)

**Open-Source Alternative:** Headscale (self-hosted coordination server)
- Can use if privacy/self-hosting is preferred
- Same Tailscale clients work with Headscale
- Adds operational overhead (must host coordination server)

**Recommendation:** Start with Tailscale free tier. Migrate to Headscale later if needed.

### Distributed Filesystem: Syncthing

**Why Syncthing:**
- True real-time sync (changes propagate immediately)
- All platforms supported: Ubuntu ARM64, WSL2, Windows native
- No master/slave - all nodes are equal peers
- Conflict handling: Keeps both versions (rename with timestamp)
- Works offline: Nodes sync when reconnected
- Fully open-source (MPL 2.0)
- Web UI and CLI for management
- Low resource usage

**Alternatives Considered:**
| Tool | Why Not |
|------|---------|
| GlusterFS | No Windows support, overkill for 3 nodes |
| Resilio Sync | Proprietary, not open-source |
| Unison | Not real-time (requires manual/cron sync) |
| rclone bisync | Not real-time, polling-based |

---

## Detailed Design

### 1. Network Layer (Tailscale)

**Hostname Resolution Strategy:**

This setup uses a hybrid approach optimized for a local network where all machines are physically close:

| Host | Local (LAN) | Remote (Internet) |
|------|-------------|-------------------|
| sfspark1 | `sfspark1` (mDNS/Avahi) | `sfspark1` (Tailscale MagicDNS) |
| office-one (WSL2) | `office-one.local:2222` (mDNS) | `office-one:2222` (MagicDNS) |
| windows | `office-one.local:22` (mDNS) | `office-one:22` (MagicDNS) |

On LAN, mDNS (`.local`) provides fast local resolution without internet dependency. Over Tailscale (remote), MagicDNS handles routing automatically. The SSH config below works for both scenarios.

**Tailscale IP Assignment:**
```
sfspark1     → 100.x.x.1  (standalone machine)
windows+WSL2 → 100.x.x.2  (shared IP, differentiated by port)
```

**Note:** WSL2 inherits the Windows host's Tailscale IP. Differentiation is by SSH port:
- Windows SSH: port 22
- WSL2 SSH: port 2222

**SSH Access Matrix:**
| From \ To | sfspark1 | office-one (WSL2) | windows |
|-----------|----------|-------------------|---------|
| sfspark1 | - | `ssh office-one -p 2222` | `ssh windows` |
| WSL2 | `ssh sfspark1` | - | `ssh windows` |
| windows | `ssh sfspark1` | `wsl -d Ubuntu-22.04` | - |

**Note:** From Windows, use `wsl` command to access WSL2 locally (faster than SSH loopback).

**SSH Config (deployed to all machines):**
```
Host sfspark1
    HostName sfspark1.local
    User steve
    IdentityFile ~/.ssh/id_ed25519

Host office-one
    HostName office-one.local
    User steve
    Port 2222
    IdentityFile ~/.ssh/id_ed25519

Host windows
    HostName office-one.local
    User steve
    IdentityFile ~/.ssh/id_ed25519
```

### 2. Storage Layer (Syncthing)

**Port Configuration (to avoid conflicts when running on same host):**
| Node | Sync Port | GUI Port | Folder Path |
|------|-----------|----------|-------------|
| sfspark1 | 22000 | 8384 | /opt/shared |
| WSL2 | 22001 | 8385 | /opt/shared (ext4) |
| Windows | 22002 | 8386 | C:\shared (NTFS) |

**Setting non-default ports:**

WSL2 (edit `~/.config/syncthing/config.xml` or use GUI):
```xml
<gui enabled="true" tls="false">
    <address>127.0.0.1:8385</address>
</gui>
<options>
    <listenAddress>tcp://:22001</listenAddress>
</options>
```

Windows (edit `%LOCALAPPDATA%\Syncthing\config.xml` or use GUI):
```xml
<gui enabled="true" tls="false">
    <address>127.0.0.1:8386</address>
</gui>
<options>
    <listenAddress>tcp://:22002</listenAddress>
</options>
```

Or via CLI before first run: `syncthing --gui-address=127.0.0.1:8385`

> **Important:** WSL2's `/opt/shared` (ext4 filesystem) and Windows' `C:\shared` (NTFS) are completely separate filesystems. Running Syncthing on both is valid - they are independent replicas with no risk of sync loops.

**Shared Folder Configuration:**
```
Folder ID: opt-shared
Folder Path:
  - sfspark1:    /opt/shared
  - WSL2:        /opt/shared (ext4, separate from Windows)
  - Windows:     C:\shared (NTFS)
```

**Sync Settings:**
- File versioning: Simple (keep 5 versions)
- Ignore patterns: `.git/index.lock`, `*.swp`, `*.tmp`, `__pycache__`
- Folder type: Send & Receive (bidirectional)
- Watch for changes: Enabled (real-time)

**Conflict Resolution:**
- Syncthing renames conflicting files: `file.txt.sync-conflict-20240115-123456-ABCDEF.txt`
- Both versions preserved for manual review
- No data loss on conflicts

**Device Discovery:**
- Global discovery: Enabled (find peers anywhere)
- Local discovery: Enabled (faster on same LAN)
- Relaying: Enabled (fallback if direct connection fails)

### 3. Authentication

**Tailscale Auth:**
- OAuth login (Google, GitHub, Microsoft, Apple)
- Device authorization via Tailscale admin console
- Optional: Tailscale ACLs for fine-grained access control

**SSH Auth:**
- Ed25519 key-based authentication (no passwords)
- Keys stored in Windows SSH agent, shared to WSL2 via npiperelay
- `authorized_keys` deployed to all machines

**Syncthing Auth:**
- Device ID exchange (cryptographic identity)
- Devices must be manually approved before syncing
- HTTPS API with API key for automation

### 4. WSL2 SSH Server Setup

WSL2 requires explicit SSH server configuration to be accessible from the network.

**Step 1: Enable systemd in WSL2**

Edit `/etc/wsl.conf` in WSL2:
```ini
[boot]
systemd=true
```

Then restart WSL from Windows: `wsl --shutdown` followed by opening a new WSL terminal.

**Step 2: Install and configure OpenSSH server**
```bash
sudo apt update && sudo apt install -y openssh-server

# Set port 2222 (handles commented, uncommented, or missing Port line)
sudo sed -i '/^#*Port /d' /etc/ssh/sshd_config
echo "Port 2222" | sudo tee -a /etc/ssh/sshd_config

sudo systemctl enable ssh
sudo systemctl start ssh
```

**Step 3: Enable mirrored networking (Windows 11 22H2+)**

Create or edit `%USERPROFILE%\.wslconfig`:
```ini
[wsl2]
networkingMode=mirrored
```

With mirrored networking, WSL2 shares the Windows host's network interfaces and is directly accessible on the LAN at `office-one.local:2222`.

**Step 4: Add Windows Firewall rule (required for both networking modes)**
```powershell
# Run as Administrator
New-NetFirewallRule -DisplayName "WSL2 SSH" -Direction Inbound -LocalPort 2222 -Protocol TCP -Action Allow
```

**Alternative: Port forwarding (Windows 10 or older Windows 11)**

If mirrored networking isn't available, use port forwarding instead of Step 3:
```powershell
# Run as Administrator - get WSL2 IP and create port proxy
$wslIp = (wsl hostname -I).Trim()
netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=$wslIp
Write-Host "Forwarding port 2222 to WSL2 at $wslIp"
```

Note: WSL2's IP can change on restart with NAT networking. Create a scheduled task to re-run this at login, or use mirrored networking to avoid this issue.

### 5. Windows Environment Details

**Default SSH shell:** MSYS2/zsh (Git Bash environment)
- Direct PowerShell: `powershell -Command "Get-Process"`
- Direct CMD: `cmd /c "dir"`

The Windows OpenSSH server uses MSYS2/zsh as the default shell, not CMD. Plan scripts accordingly.

**Windows Syncthing auto-start:** The Syncthing Windows installer automatically adds itself to startup. If installed via `winget install Syncthing.Syncthing`, check Settings → Apps → Startup to verify "Syncthing" is enabled.

### 6. WSL2 Auto-Start (SSH and Syncthing)

With systemd enabled (Step 1), services start automatically when WSL2 boots. Just enable them once:

**Inside WSL2:**
```bash
# SSH is already enabled from Step 2
sudo systemctl enable ssh

# Enable Syncthing as user service
systemctl --user enable syncthing
```

**Ensure WSL2 starts on Windows login:**

WSL2 must be running for services to work. Create a scheduled task to start it at login:

```powershell
# Run as Administrator
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d Ubuntu-22.04 -- true"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
Register-ScheduledTask -TaskName "Start WSL2" -Action $action -Trigger $trigger
```

This silently starts WSL2, and systemd will automatically start SSH and Syncthing.

**Verify services are running:**
```bash
wsl -d Ubuntu-22.04 -- systemctl status ssh syncthing@steve
```

**Note:** Replace `Ubuntu-22.04` with your actual distro name (check with `wsl -l -v`).

---

## Prerequisites / Cleanup

Before setting up the mesh network, clean up any legacy configurations.

### WSL2 Cleanup (if migrating from SSHFS/NFS)

Remove stale NFS mount from WSL2 fstab that may cause errors:
```bash
# From any machine with SSH access to WSL2
ssh steve@office-one.local -p 2222 "sudo sed -i '/nfs/d' /etc/fstab"

# Or from Windows
wsl -d Ubuntu-22.04 -e sudo sed -i '/nfs/d' /etc/fstab
```

### Verify prerequisites
```bash
# On sfspark1
tailscale status  # Should show connected
syncthing --version  # Should be installed

# On Windows
tailscale status
syncthing --version

# On WSL2
systemctl status ssh  # Should be running on port 2222
syncthing --version
```

---

## Setup Scripts

### Single Universal Script: `setup-mesh.sh`

One script that:
1. Detects OS (Ubuntu native, WSL2, Windows)
2. Installs Tailscale
3. Installs Syncthing
4. Configures SSH
5. Joins the mesh

**Script Flow:**
```
┌─────────────────────────────────────────┐
│            setup-mesh.sh                │
├─────────────────────────────────────────┤
│ 1. Detect environment                   │
│    - hostname → role                    │
│    - uname → OS type                    │
│    - Check for WSL                      │
├─────────────────────────────────────────┤
│ 2. Install Tailscale                    │
│    - Ubuntu: apt/curl script            │
│    - Windows: winget                    │
│    - WSL2: Skip (use Windows Tailscale) │
├─────────────────────────────────────────┤
│ 3. Install Syncthing                    │
│    - Ubuntu: apt                        │
│    - Windows: winget                    │
│    - WSL2: apt (inside WSL)             │
├─────────────────────────────────────────┤
│ 4. Configure SSH                        │
│    - Deploy ~/.ssh/config               │
│    - Setup SSH server if needed         │
│    - Exchange keys                      │
├─────────────────────────────────────────┤
│ 5. Configure Syncthing                  │
│    - Set folder path                    │
│    - Add peer devices                   │
│    - Enable auto-start                  │
└─────────────────────────────────────────┘
```

### Script Inventory

| Script | Purpose | Run On |
|--------|---------|--------|
| `setup-mesh.sh` | Universal setup (detects OS, installs everything) | Any machine |
| `join-tailnet.sh` | Join Tailscale network (interactive auth) | Any machine |
| `add-syncthing-peer.sh` | Add a new peer to Syncthing cluster | Any machine |
| `status.sh` | Show mesh and sync status | Any machine |
| `troubleshoot.sh` | Diagnose connectivity issues | Any machine |

### Replacing Current Scripts

| Current Script | Replacement | Notes |
|----------------|-------------|-------|
| `setup-ssh-server.sh` | `setup-mesh.sh` | Merged into universal script |
| `setup-sshfs-client.sh` | `setup-mesh.sh` | SSHFS replaced by Syncthing |
| `setup-openssh-windows.sh` | `setup-mesh.sh` | Windows detection branch |
| `setup-sshfs-windows.sh` | `setup-mesh.sh` | SSHFS-Win no longer needed |
| `setup-openssh-windows.ps1` | `setup-mesh.ps1` | PowerShell companion for Windows |
| `setup-sshfs-windows.ps1` | Removed | Not needed with Syncthing |
| `reconnect.sh` | Removed | Syncthing handles reconnection |
| `CLAUDE.md` | Updated | New documentation |

---

## Migration Plan

### Phase 1: Tailscale (Network Layer)
1. Install Tailscale on sfspark1
2. Install Tailscale on Windows (covers WSL2)
3. Verify MagicDNS: `ping sfspark1` from Windows
4. Test SSH: `ssh steve@sfspark1` from Windows
5. Update SSH config on all machines

### Phase 2: Syncthing (Storage Layer)
1. Install Syncthing on sfspark1 (existing data)
2. Install Syncthing on Windows
3. Install Syncthing in WSL2
4. Share device IDs and approve connections
5. Initial sync (sfspark1 → others)
6. Verify bidirectional sync

### Phase 3: Cleanup
1. Unmount SSHFS on office-one
2. Remove SSHFS-Win from Windows
3. Remove old setup scripts
4. Update CLAUDE.md documentation
5. Test failure scenarios (take each node offline)

### Phase 4: Validation
1. Edit file on sfspark1 → verify appears on Windows and WSL2
2. Edit file on Windows → verify appears on sfspark1 and WSL2
3. Take sfspark1 offline → verify Windows and WSL2 still work
4. Bring sfspark1 back → verify it syncs changes
5. Create conflict → verify both versions preserved

### Rollback Procedure (if needed)

If migration fails, revert to SSHFS:

1. **Stop Syncthing on all nodes:**
   ```bash
   # Linux/WSL2
   systemctl stop syncthing@steve
   # Windows: Stop via tray icon or Task Manager
   ```

2. **Restore SSHFS mounts:**
   ```bash
   # On office-one (WSL2)
   sshfs steve@sfspark1:/opt/shared /opt/shared -o reconnect,ServerAliveInterval=15
   # Or re-run the old setup-sshfs-client.sh
   ```

3. **Keep Tailscale running** - it doesn't affect SSHFS and provides better connectivity

4. **Data is safe** - Syncthing doesn't delete source files, and sfspark1 remains the authoritative copy until Phase 3 cleanup

---

## Configuration Files

### Tailscale ACL (optional, for fine-grained control)
```json
{
  "acls": [
    {"action": "accept", "src": ["*"], "dst": ["*:*"]}
  ],
  "ssh": [
    {"action": "accept", "src": ["autogroup:members"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot"]}
  ]
}
```

### Syncthing Config Snippets

**Ignore Patterns (`/opt/shared/.stignore`):**
```
// Git lock files
.git/index.lock
.git/*.lock

// Editor temp files
*.swp
*.swo
*~
.*.swp

// Python cache
__pycache__
*.pyc
.pytest_cache

// Node modules (if any)
node_modules

// OS files
.DS_Store
Thumbs.db
```

> **Deployment:** Place `.stignore` in `/opt/shared/` on sfspark1 (the initial data source). Syncthing will automatically sync this file to all nodes, ensuring consistent ignore patterns everywhere.

**Folder Configuration (via API or GUI):**
```json
{
  "id": "opt-shared",
  "label": "Shared Workspace",
  "path": "/opt/shared",
  "type": "sendreceive",
  "fsWatcherEnabled": true,
  "fsWatcherDelayS": 1,
  "versioning": {
    "type": "simple",
    "params": {"keep": "5"}
  }
}
```

### SSH Config (`~/.ssh/config`)
```
# Mesh network hosts (via Tailscale + mDNS)
Host sfspark1
    HostName sfspark1.local
    User steve
    IdentityFile ~/.ssh/id_ed25519

Host office-one
    HostName office-one.local
    User steve
    Port 2222
    IdentityFile ~/.ssh/id_ed25519

Host windows
    HostName office-one.local
    User steve
    Port 22
    IdentityFile ~/.ssh/id_ed25519

# Connection sharing for performance
Host *
    ControlMaster auto
    ControlPath ~/.ssh/control-%C
    ControlPersist 600
    AddKeysToAgent yes
```

---

## Operational Procedures

### Adding a New Machine

1. Run `setup-mesh.sh` on new machine
2. Authenticate with Tailscale (browser OAuth)
3. Get Syncthing device ID: `syncthing cli show system | grep myID`
4. On existing machine: Add new device ID in Syncthing GUI
5. Accept connection on new machine
6. Share `opt-shared` folder with new device

### Removing a Machine

1. In Syncthing GUI: Remove device from all peers
2. In Tailscale admin: Remove machine from tailnet
3. Optionally: Delete local `/opt/shared` data

### Handling Conflicts

1. Syncthing creates `filename.sync-conflict-DATE-ID.ext`
2. Review both versions
3. Keep desired version, delete conflict file
4. Or merge manually if needed

### Monitoring

**Syncthing Web UI (per-node ports):**
| Node | URL |
|------|-----|
| sfspark1 | `http://localhost:8384` |
| WSL2 | `http://localhost:8385` |
| Windows | `http://localhost:8386` |

Shows: Folder status, connected devices, transfer rates, recent changes

**Tailscale Status:**
```bash
tailscale status          # List connected peers
tailscale ping sfspark1   # Test connectivity
tailscale netcheck        # Network diagnostics
```

**Health Check Script (`status.sh`):**
```bash
#!/bin/bash
# Detect Syncthing GUI port and config path based on environment
case "$(hostname)" in
  sfspark1)
    ST_PORT=8384
    ST_CONFIG="$HOME/.config/syncthing"
    ;;
  *)
    if grep -q microsoft /proc/version 2>/dev/null; then
      ST_PORT=8385  # WSL2
      ST_CONFIG="$HOME/.config/syncthing"
    else
      ST_PORT=8386  # Windows (via Git Bash/MSYS2)
      ST_CONFIG="$LOCALAPPDATA/Syncthing"
    fi
    ;;
esac

# Get API key (try config.xml if api-key file doesn't exist)
if [[ -f "$ST_CONFIG/api-key" ]]; then
  API_KEY=$(cat "$ST_CONFIG/api-key")
else
  API_KEY=$(grep -oP '(?<=<apikey>)[^<]+' "$ST_CONFIG/config.xml" 2>/dev/null)
fi

echo "=== Tailscale Status ==="
tailscale status

echo ""
echo "=== Syncthing Status (port $ST_PORT) ==="
curl -s -H "X-API-Key: $API_KEY" \
  "http://localhost:$ST_PORT/rest/system/status" | jq -r '.myID[:8] as $id | "Device: \($id)..."'

echo ""
echo "=== Folder Status ==="
curl -s -H "X-API-Key: $API_KEY" \
  "http://localhost:$ST_PORT/rest/db/status?folder=opt-shared" | jq '{state, needFiles, needBytes}'
```

---

## Security Considerations

### Tailscale Security
- All traffic encrypted (WireGuard)
- Peer-to-peer (no data through Tailscale servers)
- Device authorization required
- Optional: MFA via identity provider

### Syncthing Security
- All traffic encrypted (TLS 1.3)
- Device IDs are cryptographic identities
- No central server (peer-to-peer)
- Local API requires API key

### SSH Security
- Key-based auth only (no passwords)
- Ed25519 keys (modern, secure)
- Optional: Tailscale SSH for SSO integration

---

## Failure Scenarios

| Scenario | Impact | Recovery |
|----------|--------|----------|
| sfspark1 offline | Other nodes continue working, changes sync when back | Automatic |
| office-one offline | Other nodes continue, WSL2 data syncs on reconnect | Automatic |
| Network partition | Nodes work independently, sync when reconnected | Automatic |
| Tailscale down | SSH via Tailscale IPs still works (cached), new connections may fail | Wait or use direct IPs |
| Syncthing crash | Local files intact, sync resumes on restart | Restart service |
| Conflict created | Both versions preserved | Manual review |

---

## Cost Analysis

| Component | Cost |
|-----------|------|
| Tailscale (Personal) | Free (100 devices, 3 users) |
| Syncthing | Free (open-source) |
| Headscale (if self-hosted) | Free + hosting costs |

**Total: $0/month** for typical personal use.

---

## Timeline Estimate

| Phase | Tasks | Duration |
|-------|-------|----------|
| Phase 1 | Tailscale setup on all machines | 30 min |
| Phase 2 | Syncthing setup and initial sync | 1-2 hours (depends on data size) |
| Phase 3 | Cleanup old scripts, update docs | 30 min |
| Phase 4 | Testing and validation | 1 hour |

**Total: ~3-4 hours** for complete migration.

---

## Open Questions

1. **Headscale vs Tailscale:** Start with Tailscale for simplicity, or self-host Headscale from day one?
   - **Recommendation:** Start with Tailscale, migrate to Headscale later if privacy concerns arise.

2. ~~**WSL2 SSH port:** Use 2222 or configure Windows to forward 22 to WSL2?~~
   - **Resolved:** Use port 2222. WSL2 SSH server setup documented in section 4.

3. ~~**Syncthing on Windows vs WSL2:** Run Syncthing on Windows native or inside WSL2?~~
   - **Resolved:** Run on both with separate ports (see Storage Layer section). Windows syncs `C:\shared` (NTFS), WSL2 syncs `/opt/shared` (ext4). These are completely separate filesystems - no sync loop risk.

4. **Initial data migration:** Copy from sfspark1 or let Syncthing sync?
   - **Recommendation:** Let Syncthing sync (it will handle it efficiently).

---

## Appendix: Research Sources

### Tailscale
- [Tailscale Quickstart](https://tailscale.com/kb/1017/install)
- [MagicDNS Documentation](https://tailscale.com/kb/1081/magicdns)
- [WSL2 + Tailscale Guide](https://www.hanselman.com/blog/using-tailscale-on-windows-to-network-more-easily-with-wsl2-and-visual-studio-code)
- [Headscale (self-hosted)](https://github.com/juanfont/headscale)

### Syncthing
- [Syncthing Documentation](https://docs.syncthing.net/)
- [Conflict Handling](https://docs.syncthing.net/users/syncing.html#conflicting-changes)
- [WSL2 Setup Guide](https://atimad.github.io/posts/Syncthing%20Data%20Science%20Friendly/)

### SSH Mesh
- [Windows OpenSSH Server](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
- [SSH into WSL2](https://www.hanselman.com/blog/how-to-ssh-into-wsl2-on-windows-10-from-an-external-machine/)
- [Sharing SSH Keys Windows/WSL2](https://devblogs.microsoft.com/commandline/sharing-ssh-keys-between-windows-and-wsl-2/)
