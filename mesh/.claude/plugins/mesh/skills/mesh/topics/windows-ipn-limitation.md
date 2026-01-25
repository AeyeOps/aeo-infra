# Windows IPN Session Isolation

This is the most significant limitation encountered in MeSH - a fundamental Windows architecture constraint that prevents automated Tailscale connection via SSH. Understanding this limitation is essential for anyone working with Windows mesh provisioning.

## The Problem

When running `tailscale up` via SSH on Windows, the command fails to communicate with the Tailscale service:

```
error: failed to connect to local Tailscale daemon;
it doesn't appear to be running (waiting for Tailscale...)
```

This happens even though the Tailscale service is running and healthy:

```powershell
PS> Get-Service Tailscale

Status   Name       DisplayName
------   ----       -----------
Running  Tailscale  Tailscale
```

The service is running, but the CLI cannot communicate with it.

## Root Cause

Windows isolates processes by security session. This is a core Windows security feature introduced in Windows Vista and refined in subsequent versions.

### Session Architecture

```
Session 0 (Services Session)
├── Services.exe
├── Tailscale Service (tailscaled.exe)
│   └── Creates named pipe: \\.\pipe\ProtectedPrefix\LocalService\tailscale-ipn
└── Other Windows services

Session 1 (Interactive Console)
├── Explorer.exe
├── User applications
└── CAN access the IPN pipe (same user context)

Session N (RDP Sessions)
├── Per-user RDP sessions
└── CAN access the IPN pipe (interactive session)

SSH Session (OpenSSH Server)
├── sshd.exe spawns processes here
├── tailscale.exe CLI runs here
└── CANNOT access the IPN pipe (isolated session)
```

### The Named Pipe

Tailscale uses a named pipe for inter-process communication between the CLI and the service:

```
\\.\pipe\ProtectedPrefix\LocalService\tailscale-ipn
```

The path components are significant:
- `\\.\pipe\` - Local named pipe namespace
- `ProtectedPrefix\` - Windows-protected namespace (restricted access)
- `LocalService\` - Created by a LocalService account process
- `tailscale-ipn` - The specific pipe name

Pipes in the `ProtectedPrefix` namespace have restricted access based on session context.

## Why This Is Fundamental

This is not a bug, misconfiguration, or oversight. It's intentional Windows security architecture:

### 1. Session 0 Isolation (Since Windows Vista)

Before Vista, services could interact directly with the user desktop. This was a security risk - a compromised service could display fake login prompts or manipulate user sessions. Vista isolated Session 0 completely from interactive sessions.

**Impact**: Services cannot display UI, and non-interactive sessions cannot access service resources designed for interactive use.

### 2. Named Pipe Access Control

Named pipes in Windows have security descriptors that control access. The Tailscale IPN pipe is created with a security descriptor that requires:
- Same user context, OR
- Interactive session token, OR
- Specific trusted process

SSH sessions have none of these qualifications.

### 3. SSH Session Context

OpenSSH Server on Windows creates a non-interactive session for each SSH connection:
- The session has a logon type of "Network" (type 3)
- It lacks the interactive session token
- It cannot access LocalService pipe namespaces
- Even running as Administrator doesn't help - it's a session context issue, not a privilege issue

## Attempted Workarounds (All Failed)

Each workaround was tested during MeSH development:

| Approach | Result | Technical Details |
|----------|--------|-------------------|
| **Service restart before connect** | Failed | The service restarts correctly, but the SSH session still can't access the pipe. Session isolation is about the client, not the server. |
| **Retry logic (3 attempts)** | Failed | This isn't a timing issue. Waiting longer doesn't change session context. |
| **Task Scheduler (SYSTEM)** | Failed | SYSTEM tasks run in Session 0, but the pipe access restriction applies even to SYSTEM processes from non-interactive contexts. |
| **Task Scheduler (Interactive)** | Failed | Interactive tasks require a logged-in user session. If one exists, they run there, but SSH can't trigger this reliably. |
| **WMI/CIM process creation** | Failed | Win32_Process.Create spawns processes in the current session context - still the isolated SSH session. |
| **Registry configuration** | Partial | Setting `HKLM:\SOFTWARE\Tailscale IPN\LoginURL` and `UnattendedMode` works for configuration, but doesn't trigger connection. The service reads these but waits for a CLI connection command. |
| **Fresh MSI install with auth key** | Failed | Even specifying auth key during install, the service state persists as "logged out" until a CLI connection is made - which requires IPN access. |
| **Clearing state files** | Failed | Deleting Tailscale state in `%ProgramData%\Tailscale` doesn't help because the issue is session access, not state corruption. |
| **PsExec -s (SYSTEM)** | Failed | Even running as SYSTEM with `-s` flag, the process is spawned from the SSH session context and inherits its limitations. |
| **PsExec -i (interactive)** | Failed | The `-i` flag requires an active interactive session (logged-in user). Without one, PsExec can't attach to an interactive session. |

### Why PsExec Doesn't Help

PsExec is often suggested as a workaround for session issues. Here's why it doesn't work:

```bash
# Via SSH - this fails
PsExec -s -accepteula "C:\Program Files\Tailscale\tailscale.exe" up --login-server=...

# Why: PsExec runs FROM the SSH session, so the target process inherits that context
```

Even with `-s` (run as SYSTEM) and `-i` (interactive), PsExec can't escape the originating session's isolation.

## The Solution

Accept the limitation and work around it gracefully:

1. **Provisioning command detects failure** after 3 retry attempts
2. **Creates PowerShell script** at `C:\temp\join-mesh.ps1` with the auth key embedded
3. **User runs script manually** in an interactive session (RDP, console, or at the machine)

### The Generated Script

```powershell
# join-mesh.ps1 - Generated by mesh remote provision

$ErrorActionPreference = 'Continue'
$TailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'
$ServerUrl = 'http://sfspark1.local:8080'
$AuthKey = 'generated-key-here'

Write-Host '=== Joining Mesh Network ===' -ForegroundColor Cyan

# Step 1: Stop any running Tailscale processes
Stop-Process -Name 'tailscale-ipn' -Force -ErrorAction SilentlyContinue
Stop-Service Tailscale -Force -ErrorAction SilentlyContinue
Start-Sleep 2

# Step 2: Configure registry for this mesh
$regPath = 'HKLM:\SOFTWARE\Tailscale IPN'
if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name 'LoginURL' -Value $ServerUrl
Set-ItemProperty -Path $regPath -Name 'UnattendedMode' -Value 'always'

# Step 3: Start fresh service
Start-Service Tailscale
Start-Sleep 3

# Step 4: Connect to mesh
& $TailscaleExe up --login-server=$ServerUrl --authkey=$AuthKey --accept-routes --unattended --reset --timeout=30s

# Step 5: Verify
& $TailscaleExe status
```

### How Users Run It

```powershell
powershell -ExecutionPolicy Bypass -File C:\temp\join-mesh.ps1
```

Or right-click → "Run with PowerShell"

## Status

**PARTIALLY AUTOMATED**: The provisioning command does everything possible via SSH:
- Installs Tailscale (winget with `--source winget` to avoid msstore cert issues)
- Restarts service with clean state
- Attempts connection with 3 retries
- On failure, creates the join script automatically

User action is limited to running one script in an interactive session.

## Verification After Manual Step

After running the script in an interactive session, verify success:

```powershell
# Check Tailscale status
& "C:\Program Files\Tailscale\tailscale.exe" status

# Expected output shows connected state:
# Health check:
#   - MagicDNS:     yes
#   - AllowedIPs:   100.64.0.2/32
#
# sfspark1.headscale     100.64.0.1     linux    -

# Test connectivity to server
& "C:\Program Files\Tailscale\tailscale.exe" ping sfspark1
# pong from sfspark1 (100.64.0.1) via 10.0.0.56:41641 in 2ms
```

## Why Interactive Sessions Work

Interactive sessions (console, RDP, or physically at the machine) have:

1. **Interactive logon type** (type 2) - grants access to interactive resources
2. **Session token** - proves interactive context to Windows security subsystem
3. **User profile loaded** - full user context available
4. **Access to LocalService pipes** - Windows grants access based on session type

The same tailscale.exe binary works in interactive sessions because Windows grants the necessary pipe access.

## Edge Cases and Considerations

### Remote Desktop Gateway

RDP sessions through an RD Gateway still work because the final session is interactive on the target machine.

### Terminal Services

Windows Server terminal services sessions are interactive and will work.

### PowerShell Remoting (WinRM)

WinRM has the same session isolation as SSH. PowerShell remoting cannot access the IPN pipe either.

### Scheduled Tasks with "Run only when user is logged on"

These tasks run in the user's interactive session IF one exists. But there's no way to guarantee a session exists when provisioning a fresh machine.

### Windows Service Recovery Actions

The Tailscale service's recovery actions run in Session 0 - they can't trigger a CLI connection.

## Future Possibilities

### What Could Change This

1. **Tailscale adding an alternative IPC mechanism** - If Tailscale exposed a TCP/HTTP API in addition to the named pipe, SSH sessions could connect via localhost
2. **Windows adding session bridge APIs** - Microsoft could add APIs to bridge session contexts, but this would be a security policy change
3. **OpenSSH Server session improvements** - If OpenSSH could be configured to create sessions with interactive-like privileges

### What Won't Help

1. **Running SSH as different users** - Session isolation is per-connection, not per-user
2. **Elevated SSH sessions** - Administrator rights don't change session type
3. **Different SSH clients/servers** - The limitation is in Windows, not OpenSSH

## Implementation Details

The script creation happens in `remote.py` around line 226. Key design decisions:

1. **PowerShell script vs batch file** - PowerShell handles escaping and error handling better
2. **Script at C:\temp** - Accessible location that doesn't require admin rights to run
3. **Embedded auth key** - User doesn't need to copy-paste the key
4. **Service restart in script** - Ensures clean state before connection attempt
5. **Registry configuration** - Sets LoginURL so the script works even after key expiration

## Related

- `./ssh-powershell-escaping.md` - How the script is created via SSH
- `../examples/troubleshoot-ipn.md` - Diagnosing IPN issues
- `../examples/provision-windows.md` - Complete Windows provisioning walkthrough
- `share-tools/docs/TESTING-GAPS.md` - Gap #2 documentation
- `share-tools/src/mesh/commands/remote.py:226-310` - Script generation implementation
