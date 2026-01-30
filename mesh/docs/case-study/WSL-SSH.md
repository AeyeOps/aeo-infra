# Deep Dive: WSL2 SSH Port Conflicts

Understanding and resolving SSH port conflicts between Windows and WSL2.

## The Problem

With WSL2 mirrored networking enabled, attempting to start SSH in WSL produces:

```
error: Bind to port 22 on 0.0.0.0 failed: Address already in use
error: Cannot bind any address.
```

## Why It Happens

### WSL2 Networking Modes

WSL2 has two networking modes:

1. **NAT mode (default):** WSL has its own virtual network adapter with a separate IP
2. **Mirrored mode:** WSL shares Windows' network interfaces directly

With mirrored mode enabled (`/etc/wsl.conf` or `.wslconfig`):
```ini
[wsl2]
networkingMode=mirrored
```

WSL and Windows share the same port space. If Windows OpenSSH Server is running on port 22, WSL cannot also bind to port 22.

### Port Conflict Diagram

```
                    Port 22
                       │
    ┌──────────────────┴──────────────────┐
    │                                      │
    ▼                                      ▼
┌────────────────┐              ┌────────────────┐
│ Windows SSH    │              │ WSL SSH        │
│ sshd.exe       │              │ /usr/sbin/sshd │
│ Status: ✓      │              │ Status: FAILED │
│ Bound to :22   │              │ Can't bind :22 │
└────────────────┘              └────────────────┘
```

## Solution: Different Ports

Configure WSL SSH to use port 2222 (or any available port).

### Step 1: Create SSH config override

```bash
sudo tee /etc/ssh/sshd_config.d/port.conf << 'SSHCONF'
Port 2222
SSHCONF
```

### Step 2: Disable socket activation

Modern Ubuntu uses socket activation for SSH. This conflicts with manual service management:

```bash
sudo systemctl disable ssh.socket
sudo systemctl stop ssh.socket
```

### Step 3: Enable and start SSH service

```bash
sudo systemctl enable ssh
sudo systemctl start ssh
```

### Step 4: Verify

```bash
ss -tlnp | grep 2222
# Should show sshd listening on port 2222
```

## Windows Firewall Configuration

WSL traffic may need explicit firewall rules, especially for access from other machines on the network.

```powershell
# Allow SSH to WSL from local network
New-NetFirewallRule -DisplayName "WSL SSH (2222)" `
    -Direction Inbound `
    -LocalPort 2222 `
    -Protocol TCP `
    -Action Allow

# For Tailscale mesh only
New-NetFirewallRule -DisplayName "WSL SSH from Tailscale" `
    -Direction Inbound `
    -RemoteAddress 100.64.0.0/10 `
    -LocalPort 2222 `
    -Protocol TCP `
    -Action Allow
```

## SSH Config on Other Machines

Update SSH configs to use the correct port for WSL:

```
Host wsl
    HostName 100.64.0.4    # Windows Tailscale IP (WSL shares it)
    Port 2222
    User myuser
```

Or from Windows itself:
```
Host wsl
    HostName localhost
    Port 2222
    User myuser
```

## Common Issues

### Issue: SSH service won't start

**Symptom:**
```bash
sudo systemctl start ssh
# Job for ssh.service failed
```

**Check:** Is ssh.socket still active?
```bash
sudo systemctl status ssh.socket
```

**Fix:** Disable and stop the socket:
```bash
sudo systemctl disable ssh.socket
sudo systemctl stop ssh.socket
sudo systemctl start ssh
```

### Issue: Connection refused from external machine

**Symptom:**
```bash
ssh wsl
# Connection refused
```

**Checks:**
1. Is SSH running in WSL?
   ```bash
   wsl -e ss -tlnp | grep 2222
   ```

2. Is Windows firewall allowing port 2222?
   ```powershell
   Get-NetFirewallRule | Where-Object { $_.LocalPort -eq 2222 }
   ```

3. Is the Tailscale IP correct?
   ```bash
   tailscale ip -4  # Run on Windows
   ```

### Issue: SSH works from Windows but not from Linux

**Symptom:** `ssh wsl` from Linux fails, but `ssh localhost -p 2222` from Windows works.

**Likely cause:** Firewall rule doesn't allow external connections.

**Fix:** Add firewall rule for Tailscale network (see above).

## Alternative: Disable Windows OpenSSH

If you don't need Windows-native SSH (only WSL SSH), you can disable Windows OpenSSH Server:

```powershell
Stop-Service sshd
Set-Service sshd -StartupType Disabled
```

Then WSL can use port 22. However, this prevents direct SSH to Windows.

## Recommended Configuration

For a mesh with both Windows and WSL as SSH targets:

| System | SSH Port | Service |
|--------|----------|---------|
| Windows | 22 | OpenSSH Server (sshd) |
| WSL | 2222 | OpenSSH Server (/usr/sbin/sshd) |

This allows:
- `ssh windows` → Windows on port 22
- `ssh wsl` → WSL on port 2222 (same IP, different port)
