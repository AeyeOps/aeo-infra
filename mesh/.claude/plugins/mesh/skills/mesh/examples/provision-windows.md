# Example: Provisioning a Windows Host

This walkthrough demonstrates provisioning a Windows machine to join the MeSH network.

## Scenario

**Target:** Windows 11 machine at `office-one.local` port 22
**User:** steve (administrator)
**Starting point:** SSH key auth already configured

## Step 1: Verify Prerequisites

From sfspark1 (the Headscale server):

```bash
# Check Headscale is running
sudo systemctl status headscale
● headscale.service - Headscale coordination server
     Active: active (running)

# Test SSH connectivity
ssh -o BatchMode=yes steve@office-one.local -p 22 "echo connected"
connected
```

## Step 2: Run Provisioning

```bash
mesh remote provision steve@office-one.local --port 22
```

**Expected output:**

```
═══ Provisioning steve@office-one.local:22 ═══

Testing SSH connectivity...
✓ SSH connection successful

Detecting remote OS...
✓ Detected OS: windows

Generating Headscale auth key...
✓ Auth key generated

Configuring Tailscale on Windows...
✓ Tailscale is installed

Restarting Tailscale service...
Connecting to mesh network...
⚠ Attempt 1/3: Service not ready, restarting...
⚠ Attempt 2/3: waiting for Tailscale...
⚠ Attempt 3/3: waiting for Tailscale...

SSH session cannot reach Tailscale service, trying PsExec...

Script created on Windows. Run in PowerShell:
────────────────────────────────────────────────────────────
  powershell -ExecutionPolicy Bypass -File C:\temp\join-mesh.ps1
────────────────────────────────────────────────────────────
Or right-click the file and select 'Run with PowerShell'

Why: Windows session isolation prevents SSH from reaching Tailscale.
```

## Step 3: Complete Windows Connection Manually

On the Windows machine (via RDP or physically):

1. **Open PowerShell** (Run as Administrator recommended)
2. **Navigate to temp:**
   ```powershell
   cd C:\temp
   ```
3. **Run the script:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\join-mesh.ps1
   ```

**Expected output:**

```
=== Joining Mesh Network ===
[1/5] Stopping Tailscale processes...
[2/5] Configuring mesh settings...
[3/5] Starting Tailscale service...
[4/5] Connecting to mesh network...
[5/5] Verifying connection...

SUCCESS: Connected to mesh network!

# Health check:
#   - MagicDNS:     yes
#   - AllowedIPs:   100.64.0.2/32
#
# sfspark1.headscale     100.64.0.1     linux    -
#
Press Enter to exit
```

## Step 4: Verify from Headscale Server

Back on sfspark1:

```bash
# List all nodes
sudo headscale nodes list

ID | Hostname | Name           | IPv4       | IPv6 | Last seen           | Online | Expired
1  | sfspark1 | sfspark1       | 100.64.0.1 |      | 2024-01-15 10:30:00 | true   | false
2  | DESKTOP  | windows-pc     | 100.64.0.2 |      | 2024-01-15 10:31:00 | true   | false

# Test connectivity
tailscale ping 100.64.0.2
pong from DESKTOP (100.64.0.2) via 10.0.0.45:41641 in 2ms
```

## Why the Manual Step?

Windows session isolation prevents SSH sessions from accessing the Tailscale named pipe. This is a fundamental Windows security feature, not a bug.

See `../topics/windows-ipn-limitation.md` for technical details on:
- What session isolation is
- Why all workarounds failed
- How the script works around it

## Troubleshooting

### Script not found

If `C:\temp\join-mesh.ps1` doesn't exist, the SSH script creation failed.

**Fallback:** Copy the command from the provisioning output and run directly:
```powershell
& "C:\Program Files\Tailscale\tailscale.exe" up --login-server=http://sfspark1.local:8080 --authkey=YOUR_KEY --accept-routes --unattended --reset
```

### Auth key expired

Pre-auth keys expire after 24 hours by default. Generate a new one:
```bash
# On sfspark1
sudo headscale preauthkeys create --user mesh --reusable --expiration 24h
```

### Tailscale not installed

If winget installation failed during provisioning, install manually:
```powershell
winget install --id Tailscale.Tailscale --source winget --accept-source-agreements --accept-package-agreements --silent
```

### DNS resolution failing (Docker VM)

If the Windows machine is in Docker and can't resolve `sfspark1.local`:
```powershell
# Edit the script to use IP
$ServerUrl = 'http://10.0.0.56:8080'  # Instead of sfspark1.local
```

## Next Steps

After successful connection:
1. Test bidirectional ping
2. Optionally install Syncthing for file sync
3. Configure any services that need mesh connectivity
