# Deep Dive: Windows Credential Isolation

The most time-consuming issue in this implementation: Windows credential storage is isolated by session type.

## The Problem

**Goal:** Map Z: drive to `\\linux-host\shared` persistently across reboots.

**Naive approach:**
1. Run `cmdkey /add:linux-host /user:myuser /pass` to store credentials
2. Create scheduled task with `net use Z: \\linux-host\shared /persistent:yes`
3. Task runs on login → Drive should be mapped

**Reality:** Task fails with "invalid password" even though credentials are stored.

## Why It Fails

Windows Credential Manager uses "Logon Types" to isolate credentials:

| Logon Type | Description | Example |
|------------|-------------|---------|
| Interactive | Physical console or RDP | Sitting at keyboard |
| Network | Remote network access | SSH session |
| Batch | Scheduled tasks | Task Scheduler |
| Service | Service accounts | Windows services |

Credentials stored in one logon type are **not visible** to other types.

### Credential Isolation Example

```
┌─────────────────────────────────────────────────────────┐
│ User "myuser" Credential Store                          │
├─────────────────────────────────────────────────────────┤
│ Interactive Session Credentials:                        │
│   └─ linux-host → myuser:******* ✓                     │
├─────────────────────────────────────────────────────────┤
│ Network Session Credentials:                            │
│   └─ (empty)                                            │
├─────────────────────────────────────────────────────────┤
│ Batch Session Credentials:                              │
│   └─ (empty) ← Scheduled task looks here!              │
└─────────────────────────────────────────────────────────┘
```

## Failed Approaches

### Approach 1: Scheduled Task with /ru flag

```powershell
schtasks /create /tn "Map Z Drive" /tr "net use Z: \\linux-host\shared" /sc onlogon /ru myuser
```

**Result:** Task runs as myuser but in batch context without credential access.

### Approach 2: EnableLinkedConnections Registry

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System
EnableLinkedConnections = 1
```

**Purpose:** Links elevated and non-elevated sessions' drive mappings.
**Result:** Doesn't help with credential isolation across logon types.

### Approach 3: Store Credentials via SSH

```bash
ssh windows 'cmdkey /add:linux-host /user:myuser /pass:hunter2'
```

**Result:** Credentials stored in Network logon type, not visible to Interactive sessions.

### Approach 4: Scheduled Task Trigger from SSH

```bash
ssh windows 'schtasks /run /tn "StoreCredentials"'
```

**Result:** Task runs in Batch context, same problem.

## Working Solution

The only reliable approach: Store credentials **and** map drive from an Interactive session.

### Step 1: Create credential setup script on shared drive

Since we can access the SMB share temporarily, place a script there:

```cmd
@echo off
echo Setting up Z: drive mapping...

REM Store credentials (will prompt for password)
cmdkey /add:linux-host /user:myuser /pass

REM Remove existing mapping if any
net use Z: /delete 2>nul

REM Map the drive
net use Z: \\linux-host\shared /persistent:yes

REM Verify
if exist Z:\ (
    echo SUCCESS: Z: drive mapped
) else (
    echo FAILED: Z: drive not accessible
)
pause
```

### Step 2: Access from Windows interactively

Either:
- Physically at the Windows machine
- RDP from another machine
- VNC or other remote desktop

### Step 3: Run the script

Navigate to `\\linux-host\shared\setup.cmd` and run it. The credentials are now stored in Interactive context.

### Step 4: Create Startup script for persistence

Place in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\map-drive.cmd`:

```cmd
@echo off
net use Z: \\linux-host\shared /persistent:yes
```

This runs in Interactive context at login, with access to the stored credentials.

## Why Startup Folder Works

```
User logs in (Interactive session)
    │
    ├─→ Credential Manager (Interactive credentials available)
    │
    └─→ Startup folder scripts run
            │
            └─→ net use Z: \\linux-host\shared
                    │
                    └─→ Uses Interactive credentials ✓
```

## Verification

From the interactive Windows session:

```cmd
REM Check stored credentials
cmdkey /list

REM Should show:
REM Target: linux-host
REM Type: Domain Password
REM User: myuser

REM Verify drive
net use Z:

REM Should show:
REM Local name        Z:
REM Remote name       \\linux-host\shared
REM Resource type     Disk
```

## Key Takeaways

1. **Session types matter:** Credentials are isolated by how you logged in
2. **SSH is Network type:** Can't store credentials for Interactive sessions
3. **Scheduled tasks are Batch type:** Can't access Interactive credentials
4. **Interactive is required:** Must use RDP, console, or remote desktop
5. **Startup folder is Interactive:** Scripts there run in the right context
