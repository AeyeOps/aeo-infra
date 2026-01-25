# Example: Troubleshooting Windows IPN Issues

This walkthrough covers diagnosing and resolving Windows Tailscale IPN session isolation issues.

## Symptoms

When running `tailscale up` via SSH on Windows:

```
error: failed to connect to local Tailscale daemon;
it doesn't appear to be running (waiting for Tailscale...)
```

Or:

```
The Tailscale client is not connected to the daemon.
```

Even though:
```powershell
Get-Service Tailscale
# Status: Running
```

## Understanding the Problem

This is **not a bug** - it's Windows session isolation by design.

### How Sessions Work

```
Session 0 (Services)
├── Tailscale Service
│   └── tailscale-ipn pipe (protected)
│
Session 1+ (Interactive Users)
├── RDP/Console sessions
│   └── Can access tailscale-ipn pipe
│
SSH Session (Isolated)
└── Cannot access tailscale-ipn pipe ❌
```

### The Named Pipe

Tailscale uses this named pipe for IPC:
```
\\.\pipe\ProtectedPrefix\LocalService\tailscale-ipn
```

The `ProtectedPrefix\LocalService` path is restricted by Windows - only processes in trusted sessions can access it.

## Diagnosis Steps

### Step 1: Verify Service is Running

```powershell
Get-Service Tailscale

Status   Name     DisplayName
------   ----     -----------
Running  Tailscale Tailscale
```

### Step 2: Check Tailscale State

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" status

# If IPN issue, you'll see:
# error: failed to connect to local Tailscale daemon...
```

### Step 3: Verify This is Session Isolation

Try the same command in an interactive session (RDP or console):

```powershell
# This should work
& "C:\Program Files\Tailscale\tailscale.exe" status
```

If it works interactively but not via SSH, you've confirmed session isolation.

### Step 4: Check the Tray Application

Sometimes the tray app interferes. Try killing it:

```powershell
Stop-Process -Name "tailscale-ipn" -Force -ErrorAction SilentlyContinue
```

## Resolution Options

### Option 1: Use the Generated Script (Recommended)

The `mesh remote provision` command creates `C:\temp\join-mesh.ps1`.

Run it in an interactive session:

```powershell
powershell -ExecutionPolicy Bypass -File C:\temp\join-mesh.ps1
```

### Option 2: Manual Connection

In an interactive PowerShell session:

```powershell
$ServerUrl = "http://sfspark1.local:8080"
$AuthKey = "your-auth-key"

# Clean start
Stop-Service Tailscale -Force
Start-Sleep 2
Start-Service Tailscale
Start-Sleep 3

# Connect
& "C:\Program Files\Tailscale\tailscale.exe" up `
    --login-server=$ServerUrl `
    --authkey=$AuthKey `
    --accept-routes `
    --unattended `
    --reset
```

### Option 3: Use the System Tray

1. Click the Tailscale tray icon
2. Click "Log in..."
3. When prompted for control server, select "Custom" and enter: `http://sfspark1.local:8080`
4. Complete the authentication flow

### Option 4: Registry + Reboot

Set registry values and reboot to trigger connection:

```powershell
$regPath = 'HKLM:\SOFTWARE\Tailscale IPN'
New-Item -Path $regPath -Force | Out-Null
Set-ItemProperty -Path $regPath -Name 'LoginURL' -Value 'http://sfspark1.local:8080'
Set-ItemProperty -Path $regPath -Name 'UnattendedMode' -Value 'always'

# Reboot required for registry settings to take effect
Restart-Computer
```

Note: This only sets up the target server. You still need to provide auth key via an interactive method.

## What Does NOT Work

These approaches were tested and failed:

| Approach | Why It Failed |
|----------|---------------|
| Service restart | Session isolation persists |
| Task Scheduler (SYSTEM) | SYSTEM runs in Session 0, same isolation |
| Task Scheduler (Interactive) | Requires logged-in user, still isolated |
| WMI/CIM process creation | Same session isolation |
| PsExec -s (SYSTEM) | Session isolation |
| PsExec -i (interactive) | No interactive session available |

## Verification

After successful connection:

```powershell
# Check status
& "C:\Program Files\Tailscale\tailscale.exe" status

# Health check:
#   - MagicDNS:     yes
#   - AllowedIPs:   100.64.0.2/32

# Ping the server
& "C:\Program Files\Tailscale\tailscale.exe" ping sfspark1
pong from sfspark1 (100.64.0.1) via 10.0.0.56:41641 in 2ms
```

## Prevention for New Installs

For automated deployments (e.g., custom Windows images):

1. Include Tailscale MSI in the image
2. Set registry values during image customization
3. On first boot, a logged-in user session triggers connection

This won't help for SSH-only provisioning, but works for interactive deployments.

## Related

- `../topics/windows-ipn-limitation.md` - Full technical explanation
- `./provision-windows.md` - Complete Windows provisioning walkthrough
- `share-tools/docs/TESTING-GAPS.md` - Original gap documentation
