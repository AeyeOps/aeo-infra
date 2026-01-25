# Provisioning Sequence

The `mesh remote provision` command follows a structured sequence to add hosts to the mesh network. This document provides a detailed breakdown of each step, error handling, and customization options.

## Design Principles

The provisioning sequence is designed around several key principles:

1. **Fail fast** - Detect problems early and provide clear error messages
2. **Idempotent** - Running provision multiple times is safe
3. **OS-agnostic start** - The sequence begins identically for all hosts
4. **OS-specific finish** - Diverges based on detected operating system
5. **Graceful degradation** - When full automation isn't possible (Windows), provide clear manual steps

## Sequence Overview

```
┌─────────────────────┐
│ Test SSH Connection │
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│   Detect Remote OS  │
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ Generate Auth Key   │
│ (from Headscale)    │
└─────────┬───────────┘
          ▼
    ┌─────┴─────┐
    ▼           ▼
┌───────┐   ┌─────────┐
│ Linux │   │ Windows │
└───┬───┘   └────┬────┘
    ▼            ▼
┌───────────────────────┐
│ Install Tailscale     │
│ (curl/winget)         │
└───────────┬───────────┘
            ▼
┌───────────────────────┐
│ Connect to Mesh       │
│ (tailscale up)        │
└───────────┬───────────┘
            ▼
┌───────────────────────┐
│ Install Syncthing     │
│ (Linux only)          │
└───────────────────────┘
```

## Step 1: SSH Connectivity Test

```python
success, output = ssh_run(host, port, "echo connected")
```

Uses non-interactive SSH with:
- `BatchMode=yes` - No password prompts
- `ConnectTimeout=10` - Fast failure on unreachable hosts
- `StrictHostKeyChecking=accept-new` - Auto-accept new host keys

**Failure**: Exit immediately with SSH error details.

## Step 2: OS Detection

Tries multiple approaches:

```python
# Try uname first (Linux/macOS/MSYS)
ssh_run(host, port, "uname -s")

# If that fails, try Windows-specific
ssh_run(host, port, "echo %OS%")

# Fallback to PowerShell
ssh_run(host, port, 'powershell -Command "$env:OS"')
```

Returns: `linux`, `windows`, `macos`, or `None`

## Step 3: Auth Key Generation

Calls Headscale to create a pre-authentication key:

```python
auth_key = create_preauth_key(user)
```

This runs on the local machine (sfspark1) where Headscale is running:
```bash
sudo headscale preauthkeys create --user mesh --reusable --expiration 24h
```

**Failure**: Ensure Headscale service is running.

## Step 4: OS-Specific Provisioning

### Linux Flow

1. **Check if installed**: `which tailscale`
2. **Install if needed**: `curl -fsSL https://tailscale.com/install.sh | sudo sh`
3. **Connect**: `sudo tailscale up --login-server=URL --authkey=KEY --accept-routes`
4. **Verify**: `tailscale ip -4`

**sudo requirement**: If sudo prompts for password, provisioning fails. Run `mesh remote prepare` first.

### Windows Flow

1. **Check if installed**: `Test-Path 'C:\Program Files\Tailscale\tailscale.exe'`
2. **Install if needed**: `winget install --id Tailscale.Tailscale --source winget`
3. **Restart service**: Stop/Start with sleep intervals
4. **Attempt connection**: Up to 3 retries
5. **On failure**: Create `join-mesh.ps1` for manual execution

**IPN limitation**: Windows cannot complete connection via SSH. See `./windows-ipn-limitation.md`.

## Step 5: Syncthing Installation (Linux Only)

```bash
sudo apt-get update && sudo apt-get install -y syncthing
```

Skipped with `--skip-syncthing` flag or on Windows.

## Command Reference

### Basic Provisioning
```bash
mesh remote provision steve@office-one.local
```

### WSL (Different Port)
```bash
mesh remote provision steve@office-one.local --port 2222
```

### Custom Server
```bash
mesh remote provision user@host --server http://10.0.0.56:8080
```

### Provision All Known Hosts
```bash
mesh remote provision-all
```

## Preparing Linux Hosts

For Linux hosts that require sudo password:

```bash
mesh remote prepare steve@office-one.local --port 2222
```

This interactively configures passwordless sudo for mesh-related commands:
- `/usr/bin/tailscale*`
- `/usr/bin/apt-get update/install`
- `/bin/systemctl * tailscaled*`

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| SSH connection failed | Host unreachable or wrong credentials | Check network, SSH config |
| Could not detect OS | Non-standard SSH environment | Check shell compatibility |
| Failed to generate auth key | Headscale not running | `sudo systemctl start headscale` |
| sudo requires password | Non-interactive SSH can't prompt | Run `mesh remote prepare` |
| Tailscale install failed | Network issue or permissions | Check internet, run as admin |
| IPN issue (Windows) | Session isolation | Run generated script manually |

## Timeouts

| Operation | Timeout | Rationale |
|-----------|---------|-----------|
| SSH command (default) | 120s | Allows for slow network operations |
| SSH connectivity test | 10s | Fast failure for unreachable hosts |
| OS detection | 15s | Quick command, but allow for slow starts |
| Tailscale install | 180s | Download + install can be slow |
| Tailscale connect | 60s | Connection establishment with retries |
| Script creation | 15s | Writing join-mesh.ps1 on Windows |

### Timeout Behavior

When a timeout is exceeded:
1. The subprocess is terminated
2. The function returns `(False, "Command timed out")`
3. Provisioning fails with a clear error message

Timeouts are generous to handle slow networks or systems, but not so long that failures take forever to detect.

## Retry Logic

### Windows Connection Retries

Windows provisioning includes retry logic for the connection step:

```python
for attempt in range(1, 4):
    success, output = ssh_run(host, port, up_cmd, timeout=60)
    if success:
        ok("Connected to mesh network")
        break

    # Check if already connected
    if "100.64" in status:
        ok("Already connected to mesh")
        break

    if attempt < 3:
        # Restart service and try again
        ssh_run(host, port, restart_cmd, timeout=30)
```

This handles transient issues like:
- Service not fully started after install
- Temporary network glitches
- Previous state interfering with connection

After 3 failures, the script creation fallback activates.

### No Retries for Other Steps

Other steps don't retry because:
- **SSH connectivity**: If SSH fails, the host is unreachable
- **OS detection**: If we can't detect OS, something is fundamentally wrong
- **Auth key generation**: Headscale either works or doesn't
- **Tailscale install**: Installation failures need investigation

## State Machine Perspective

The provisioning can be viewed as a state machine:

```
                      ┌─────────────────┐
                      │     START       │
                      └────────┬────────┘
                               │
                      ┌────────▼────────┐
                      │   SSH_TESTING   │──(fail)──► EXIT_ERROR
                      └────────┬────────┘
                               │(pass)
                      ┌────────▼────────┐
                      │   OS_DETECTING  │──(fail)──► EXIT_ERROR
                      └────────┬────────┘
                               │(detected)
                      ┌────────▼────────┐
                      │  KEY_GENERATING │──(fail)──► EXIT_ERROR
                      └────────┬────────┘
                               │(key ready)
               ┌───────────────┴───────────────┐
               ▼                               ▼
        ┌──────────┐                    ┌──────────┐
        │  LINUX   │                    │ WINDOWS  │
        └────┬─────┘                    └────┬─────┘
             │                               │
             ▼                               ▼
    ┌───────────────┐               ┌───────────────┐
    │   INSTALLING  │               │   INSTALLING  │
    └───────┬───────┘               └───────┬───────┘
            │                               │
            ▼                               ▼
    ┌───────────────┐               ┌───────────────┐
    │  CONNECTING   │               │   RETRYING    │◄─┐
    └───────┬───────┘               └───────┬───────┘  │
            │                               │(fail)────┘
            │(success)                      │(3 fails)
            ▼                               ▼
    ┌───────────────┐               ┌───────────────┐
    │  SYNCTHING    │               │SCRIPT_CREATING│
    └───────┬───────┘               └───────┬───────┘
            │                               │
            ▼                               ▼
    ┌───────────────┐               ┌───────────────┐
    │   SUCCESS     │               │ MANUAL_NEEDED │
    └───────────────┘               └───────────────┘
```

## Customization Options

### Command-Line Arguments

```
mesh remote provision [OPTIONS] HOST

Arguments:
  HOST  Remote host in format user@hostname or hostname

Options:
  -p, --port INTEGER      SSH port (default: 22)
  -s, --server TEXT       Headscale server URL (default: http://sfspark1.local:8080)
  -u, --user TEXT         Headscale user/namespace (default: mesh)
  --skip-syncthing        Skip Syncthing installation
```

### Environment Variables

Currently, the mesh CLI reads configuration from command-line arguments only. Environment variable support could be added for:
- Default server URL
- Default Headscale user
- Custom SSH options

### Extending for New OS Types

To add support for a new OS (e.g., macOS):

1. Update `detect_remote_os()` to recognize the OS
2. Add a new `provision_macos()` function
3. Add the case to the dispatch in `provision()`
4. Handle any OS-specific quirks

## Logging and Debugging

### Verbose Output

The mesh CLI uses color-coded output:
- `ok("message")` - Green checkmark for success
- `info("message")` - Blue info for status updates
- `warn("message")` - Yellow warning for non-fatal issues
- `error("message")` - Red for errors
- `section("title")` - Header for major steps

### Debug SSH Commands

To debug what SSH commands are being run:

```python
# In ssh_run(), add logging:
print(f"Running: {' '.join(ssh_cmd)}")
```

### Capturing Full Output

The `ssh_run()` function captures both stdout and stderr:

```python
return result.returncode == 0, result.stdout + result.stderr
```

This ensures error messages from remote commands are visible.

## Implementation Location

The provisioning sequence is implemented in:

```
share-tools/src/mesh/commands/remote.py
```

Key functions:
- `provision()` - Main entry point (line 324)
- `provision_linux()` - Linux-specific flow (line 72)
- `provision_windows()` - Windows-specific flow (line 124)
- `ssh_run()` - SSH command wrapper (line 28)
- `detect_remote_os()` - OS detection (line 45)

## Related

- `./windows-ipn-limitation.md` - Windows-specific challenges
- `./multi-host-ssh.md` - SSH configuration
- `./testing-gaps.md` - Known issues discovered during development
- `../examples/provision-windows.md` - Windows walkthrough
- `../examples/provision-wsl.md` - WSL walkthrough
- `../references/port-reference.md` - Port assignments
