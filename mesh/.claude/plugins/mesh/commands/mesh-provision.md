---
description: Provision a remote host to join the mesh network
argument-hint: <user@host>
allowed-tools: ["Bash", "Read"]
---

# /mesh-provision

Provision a remote host to join the MeSH network via SSH.

## Usage

```
/mesh-provision steve@office-one.local              # Windows (port 22)
/mesh-provision steve@office-one.local --port 2222  # WSL
```

## Prerequisites

1. **SSH connectivity** - Key-based auth configured to target
2. **Headscale running** - On sfspark1: `sudo systemctl status headscale`
3. **For Linux targets** - Run `mesh remote prepare` first if sudo requires password

## Procedure

### Step 1: Verify SSH Connectivity

Test that SSH works without password:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 user@host -p PORT "echo connected"
```

If this fails:
- Verify SSH key is in authorized_keys
- Check correct port (22 for Windows, 2222 for WSL)
- Ensure SSH service is running on target

### Step 2: Detect Target OS

The mesh CLI auto-detects OS, but for manual verification:

```bash
# Linux/WSL
ssh user@host "uname -s"

# Windows
ssh user@host "echo %OS%"
```

### Step 3: Use mesh CLI

The recommended approach is to use the mesh CLI:

```bash
mesh remote provision user@host --port PORT --server http://sfspark1.local:8080
```

This handles:
- OS detection
- Auth key generation
- Tailscale installation
- Connection setup
- Syncthing installation (Linux)

### Step 4: Handle Windows IPN Issue

For Windows targets, the automated provisioning will likely encounter the IPN session isolation issue.

When this happens, the command:
1. Creates `C:\temp\join-mesh.ps1` on the Windows machine
2. Displays instructions for manual execution

**User action required:**
```powershell
powershell -ExecutionPolicy Bypass -File C:\temp\join-mesh.ps1
```

Run this in an interactive session (RDP, console, or physically at the machine).

### Step 5: Verify Connection

After provisioning completes:

```bash
# Check from Headscale server
sudo headscale nodes list

# Check from the provisioned machine
tailscale status
tailscale ping sfspark1
```

## Manual Provisioning (if CLI unavailable)

### Linux

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sudo sh

# Get auth key from sfspark1
AUTH_KEY=$(sudo headscale preauthkeys create --user mesh --reusable --expiration 24h | grep -o 'tskey-[a-z0-9]*')

# Connect
sudo tailscale up --login-server=http://sfspark1.local:8080 --authkey=$AUTH_KEY --accept-routes
```

### Windows

```powershell
# Install via winget
winget install --id Tailscale.Tailscale --source winget --accept-source-agreements --accept-package-agreements --silent

# After installation, run in interactive PowerShell:
$SERVER = "http://sfspark1.local:8080"
$KEY = "your-auth-key-here"

Stop-Service Tailscale -Force
Start-Sleep 2
Start-Service Tailscale
Start-Sleep 3

& "C:\Program Files\Tailscale\tailscale.exe" up --login-server=$SERVER --authkey=$KEY --accept-routes --unattended --reset
```

## Troubleshooting

### "sudo requires password"

Run `mesh remote prepare` first:
```bash
mesh remote prepare user@host --port PORT
```

### "Failed to generate auth key"

Ensure Headscale is running:
```bash
sudo systemctl start headscale
sudo systemctl status headscale
```

### Windows: "waiting for Tailscale" error

This is the IPN session isolation issue. The script has been created at `C:\temp\join-mesh.ps1`. Run it manually in an interactive session.

### Docker VM: DNS resolution failing

Use IP address instead of hostname:
```bash
mesh remote provision user@host --server http://10.0.0.56:8080
```

## Related

- `./mesh-status.md` - Check mesh status
- `skills/mesh/topics/windows-ipn-limitation.md` - Why Windows needs manual step
- `skills/mesh/topics/provisioning-sequence.md` - Full provisioning flow
