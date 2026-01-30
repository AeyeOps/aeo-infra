# Implementation Journey

Chronological account of establishing the three-node mesh network.

## Phase 1: Tailscale Mesh Connectivity

**Already in place:** Headscale server running, all nodes connected to mesh.

Verification:
```bash
# From any node
tailscale status
```

All nodes had stable 100.64.x.x addresses assigned.

## Phase 2: SSH Configuration

### Linux Host SSH Config

Created `~/.ssh/config`:
```
Host windows
    HostName 100.64.0.4
    User myuser

Host wsl
    HostName 100.64.0.4
    Port 2222
    User myuser
```

### Windows SSH Config

Created `%USERPROFILE%\.ssh\config`:
```
Host linux-host
    HostName 100.64.0.1
    User myuser

Host wsl
    HostName localhost
    Port 2222
    User myuser
```

### WSL SSH Config

Created `~/.ssh/config`:
```
Host linux-host
    HostName 100.64.0.1
    User myuser

Host windows
    HostName localhost
    User myuser
```

## Phase 3: WSL SSH Service (The Port Conflict)

**Problem:** Windows OpenSSH Server runs on port 22. WSL2 in mirrored networking mode shares the port space.

**Initial error:**
```
error: Bind to port 22 on 0.0.0.0 failed: Address already in use
```

**Solution:**

1. Configure WSL SSH on alternate port:
   ```bash
   # /etc/ssh/sshd_config.d/port.conf
   Port 2222
   ```

2. Disable socket activation (conflicts with manual service):
   ```bash
   sudo systemctl disable ssh.socket
   sudo systemctl stop ssh.socket
   ```

3. Enable and start SSH service:
   ```bash
   sudo systemctl enable ssh
   sudo systemctl start ssh
   ```

4. Add Windows firewall rule (from Windows):
   ```powershell
   New-NetFirewallRule -DisplayName "WSL SSH" -Direction Inbound -LocalPort 2222 -Protocol TCP -Action Allow
   ```

## Phase 4: Samba Share (Linux → Windows)

**Goal:** Windows can access Linux files via SMB.

1. Install Samba on Linux:
   ```bash
   sudo apt install samba
   ```

2. Create share in `/etc/samba/smb.conf`:
   ```ini
   [shared]
       path = /opt/shared
       browseable = yes
       read only = no
       guest ok = no
       valid users = myuser
       create mask = 0664
       directory mask = 0775
   ```

3. Set Samba password:
   ```bash
   sudo smbpasswd -a myuser
   ```

4. Restart Samba:
   ```bash
   sudo systemctl restart smbd
   ```

5. Open firewall:
   ```bash
   sudo ufw allow from 100.64.0.0/10 to any port 445
   ```

## Phase 5: Windows Drive Mapping (The Credential Nightmare)

See [WINDOWS-CREDENTIALS.md](WINDOWS-CREDENTIALS.md) for the full story.

**TL;DR:** 
- Scheduled tasks run in isolated credential context
- cmdkey credentials are per-session-type
- Solution: Startup folder script + credentials stored from interactive session

**Final solution:**

1. Store credentials from Windows GUI session:
   ```cmd
   cmdkey /add:linux-host /user:myuser /pass
   ```

2. Create startup script at:
   ```
   %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\map-drive.cmd
   ```
   
   Contents:
   ```cmd
   @echo off
   net use Z: \\linux-host\shared /persistent:yes
   ```

## Phase 6: NFS Share (Linux → WSL)

**Goal:** WSL can mount Linux shared directory via NFS.

1. Install NFS server on Linux:
   ```bash
   sudo apt install nfs-kernel-server
   ```

2. Configure export in `/etc/exports`:
   ```
   /opt/shared 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)
   ```

3. Export and restart:
   ```bash
   sudo exportfs -ra
   sudo systemctl restart nfs-kernel-server
   ```

4. Mount from WSL:
   ```bash
   sudo mount -t nfs linux-host:/opt/shared /mnt/shared
   ```

5. Add to `/etc/fstab` for persistence:
   ```
   linux-host:/opt/shared /mnt/shared nfs defaults 0 0
   ```

## Phase 7: Agent Protection

Created documentation to prevent AI coding assistants from breaking the setup.

See [AGENT-PROTECTION.md](AGENT-PROTECTION.md).

## Verification

From Linux:
```bash
ssh windows hostname        # Windows hostname
ssh wsl hostname            # WSL hostname
ls /opt/shared              # Local shared dir
```

From Windows:
```cmd
ssh linux-host hostname     # Linux hostname
dir Z:\                     # Mapped drive
```

From WSL:
```bash
ssh linux-host hostname     # Linux hostname
ls /mnt/shared              # NFS mount
```
