---
name: MeSH
description: This skill should be used when the user asks about "mesh remote provision", "Windows Tailscale IPN issue", "SSH to PowerShell escaping", "multi-host SSH configuration", "troubleshoot mesh connectivity", "mesh plugin", "headscale provisioning", or needs guidance on multi-machine mesh network setup with Headscale and Tailscale.
version: 1.0.0
---

# MeSH - Mesh Environment for Shared Hosts

MeSH provides patterns and knowledge for multi-machine provisioning using Headscale (self-hosted Tailscale control server), SSH configuration, and Windows-specific integration challenges. This skill covers the complete lifecycle of mesh network setup, from initial Headscale server configuration through client provisioning and ongoing troubleshooting.

## Core Architecture

The mesh network uses Headscale as a self-hosted coordination server, eliminating dependency on external Tailscale accounts:

```
sfspark1 (Headscale Server) - 100.64.0.1
├─ headscale serve (:8080)       # Coordination server
├─ Tailscale client              # Connects to localhost:8080
└─ Syncthing (:8384)             # File synchronization
        │
        ↓ WireGuard mesh (encrypted peer-to-peer)
        │
office-one (Windows + WSL2)
├─ Windows Tailscale - 100.64.0.2
│   ├─ Connects to sfspark1:8080
│   └─ Syncthing (:8386)
└─ WSL2 Tailscale - 100.64.0.3
    ├─ Connects to sfspark1:8080
    └─ Syncthing (:8385)
```

**Key design decisions:**
- **Self-hosted Headscale** eliminates external account dependencies and provides full control
- **WireGuard mesh** enables direct peer-to-peer encrypted connections after initial coordination
- **Syncthing** provides bidirectional file sync that works independently once peers connect
- **Separate Tailscale IPs** for Windows and WSL2 allow independent network identity

## Provisioning Workflow

Remote provisioning runs from the Headscale server (sfspark1) via SSH. The mesh CLI automates the complete flow.

### Linux Provisioning (Fully Automated)

Linux hosts can be fully provisioned via SSH without manual intervention:

```bash
# One-time preparation (if sudo requires password)
mesh remote prepare steve@office-one.local --port 2222

# Provision the host
mesh remote provision steve@office-one.local --port 2222
```

The provisioning sequence:
1. **SSH connectivity test** - Verify BatchMode SSH works
2. **OS detection** - Run `uname -s` to confirm Linux
3. **Auth key generation** - Call Headscale to create pre-auth key
4. **Tailscale installation** - `curl -fsSL https://tailscale.com/install.sh | sudo sh`
5. **Mesh connection** - `sudo tailscale up --login-server=URL --authkey=KEY`
6. **Syncthing installation** - `sudo apt-get install syncthing`
7. **Verification** - Confirm Tailscale IP assigned

### Windows Provisioning (Partially Automated)

Windows provisioning requires one manual step due to session isolation:

```bash
mesh remote provision steve@office-one.local --port 22
```

The command completes steps 1-4, then:
5. **Attempts connection** - Retries 3 times with service restarts
6. **Detects IPN failure** - Windows session isolation blocks named pipe access
7. **Creates join script** - Writes `C:\temp\join-mesh.ps1` with auth key
8. **Displays instructions** - User runs script in interactive session

**Manual step required:**
```powershell
powershell -ExecutionPolicy Bypass -File C:\temp\join-mesh.ps1
```

This is a fundamental Windows limitation, not a bug. See `./topics/windows-ipn-limitation.md` for technical details.

## Critical Limitation: Windows IPN Session Isolation

Windows isolates processes by security session. The Tailscale service runs in Session 0 (services), while SSH creates processes in an isolated session that cannot access the Tailscale IPN named pipe.

**The named pipe:**
```
\\.\pipe\ProtectedPrefix\LocalService\tailscale-ipn
```

**Why this matters:**
- SSH sessions cannot communicate with Tailscale service
- Task Scheduler (even as SYSTEM) has the same limitation
- PsExec with -s or -i flags also fails
- This is intentional Windows security, not misconfiguration

**The workaround:**
The provisioning command creates a PowerShell script with the correct auth key. Running this script in an interactive session (RDP, console, or physically at the machine) succeeds because interactive sessions can access the IPN pipe.

See `./topics/windows-ipn-limitation.md` for the complete list of attempted workarounds and why each failed.

## SSH Configuration Patterns

Multi-host SSH uses distinct ports to avoid conflicts:

| Host | Port | User | Description |
|------|------|------|-------------|
| windows | 22 | steve | Windows OpenSSH Server |
| wsl | 2222 | steve | WSL2 SSH (different port) |
| windows-vm | 2222 | Docker | Test VM in Docker |

**SSH options for non-interactive provisioning:**
```python
SSH_OPTS = [
    "-o", "BatchMode=yes",           # No password prompts
    "-o", "ConnectTimeout=10",       # Fast failure
    "-o", "StrictHostKeyChecking=accept-new",  # Auto-accept new keys
]
```

**Why these options:**
- `BatchMode=yes` ensures scripts don't hang waiting for password input
- `ConnectTimeout=10` fails fast if host is unreachable
- `StrictHostKeyChecking=accept-new` accepts first-time connections but still rejects changed keys (MITM protection)

See `./topics/multi-host-ssh.md` for complete configuration including key setup.

## Troubleshooting Decision Tree

Use this flowchart to diagnose common issues:

```
Connection failing?
├─ SSH connection refused
│   ├─ Check: Is SSH server running on target?
│   ├─ Check: Correct port? (22 for Windows, 2222 for WSL)
│   └─ Check: Firewall allows the port?
│
├─ SSH permission denied
│   ├─ Check: Key in authorized_keys?
│   ├─ Check: Windows admin keys in correct location?
│   └─ Action: Run ssh-copy-id or manual key setup
│
├─ sudo requires password (Linux)
│   └─ Action: Run `mesh remote prepare` first
│
├─ "waiting for Tailscale" (Windows)
│   ├─ Cause: IPN session isolation
│   └─ Action: Run C:\temp\join-mesh.ps1 interactively
│
├─ Tailscale install failed
│   ├─ Linux: Check internet connectivity
│   └─ Windows: Try `winget install --source winget` manually
│
├─ Auth key generation failed
│   └─ Check: Is Headscale running? `sudo systemctl status headscale`
│
└─ DNS resolution failing (Docker VM)
    └─ Action: Use IP address instead of .local hostname
```

## Quick Reference Commands

### Headscale Server (sfspark1)

```bash
# Check server status
sudo systemctl status headscale

# List connected nodes
sudo headscale nodes list

# Generate new auth key
sudo headscale preauthkeys create --user mesh --reusable --expiration 24h

# View auth keys
sudo headscale preauthkeys list --user mesh
```

### Tailscale Client (any node)

```bash
# Check connection status
tailscale status

# Get local Tailscale IP
tailscale ip -4

# Ping another mesh node
tailscale ping sfspark1

# Reconnect with new key
sudo tailscale up --login-server=http://sfspark1.local:8080 --authkey=KEY
```

### Mesh CLI

```bash
# Provision a Linux host
mesh remote provision user@host --port 2222

# Provision a Windows host
mesh remote provision user@host --port 22

# Prepare Linux for passwordless sudo
mesh remote prepare user@host --port 2222

# Check remote status
mesh remote status user@host --port 22

# Provision all known hosts
mesh remote provision-all
```

## Topic Reference

| Topic | When to Read | File |
|-------|--------------|------|
| Windows IPN limitation | Windows provisioning fails with "waiting for Tailscale" | `./topics/windows-ipn-limitation.md` |
| SSH→PowerShell escaping | Creating scripts to run on Windows via SSH | `./topics/ssh-powershell-escaping.md` |
| Provisioning sequence | Understanding the full provisioning flow | `./topics/provisioning-sequence.md` |
| Multi-host SSH config | Setting up SSH for multiple hosts | `./topics/multi-host-ssh.md` |
| Testing gaps & fixes | Known issues and their resolutions | `./topics/testing-gaps.md` |

## Example Workflows

| Scenario | When to Use | File |
|----------|-------------|------|
| Provision Windows host | Adding a Windows machine to mesh | `./examples/provision-windows.md` |
| Provision WSL2 host | Adding WSL2 instance to mesh | `./examples/provision-wsl.md` |
| Troubleshoot IPN issues | Windows shows "waiting for Tailscale" | `./examples/troubleshoot-ipn.md` |
| Create SSH→PowerShell scripts | Need to run complex PowerShell via SSH | `./examples/ssh-script-creation.md` |

## Technical References

| Reference | Purpose | File |
|-----------|---------|------|
| Escaping patterns | Character escaping quick reference | `./references/escaping-reference.md` |
| Port assignments | All port numbers used in mesh | `./references/port-reference.md` |

## Key Implementation Files

| File | Purpose |
|------|---------|
| `share-tools/src/mesh/commands/remote.py` | Remote provisioning implementation |
| `share-tools/docs/TESTING-GAPS.md` | Documented gaps from testing |
| `~/.ssh/config` | SSH host configuration |

## Common Patterns

### Pattern: Checking Mesh Health

To verify the entire mesh is functioning:

```bash
# On Headscale server
sudo headscale nodes list          # All registered nodes
tailscale status                   # Local connection state

# Test connectivity to each node
tailscale ping windows-pc          # Ping by Tailscale hostname
tailscale ping 100.64.0.2          # Ping by Tailscale IP
```

### Pattern: Recovering from Auth Key Expiration

Pre-auth keys expire after 24 hours by default. To reconnect a node:

```bash
# Generate new key on Headscale server
sudo headscale preauthkeys create --user mesh --reusable --expiration 24h

# On the disconnected node (Linux)
sudo tailscale up --login-server=http://sfspark1.local:8080 --authkey=NEW_KEY --force-reauth

# On Windows, update and re-run join-mesh.ps1 with new key
```

### Pattern: Adding a New Machine Type

When adding a machine type not previously provisioned:

1. Ensure SSH access is configured (key-based, correct port)
2. Run `mesh remote prepare` if Linux and sudo requires password
3. Run `mesh remote provision` with appropriate port
4. If Windows, complete manual step with join-mesh.ps1
5. Verify with `tailscale status` on both ends
6. Add to `~/.ssh/config` for convenient access

## When to Use This Skill

This skill triggers for:
- **Provisioning**: Adding new hosts to the mesh network
- **Windows issues**: Diagnosing Tailscale connection failures on Windows
- **SSH scripting**: Writing scripts that run PowerShell commands via SSH
- **SSH configuration**: Setting up SSH for multiple hosts with different ports
- **Architecture**: Understanding the Headscale/Tailscale mesh design
- **Troubleshooting**: Diagnosing connectivity issues between mesh nodes

## Design Philosophy

The MeSH approach prioritizes:

1. **Self-hosting**: No external account dependencies or service subscriptions
2. **Automation where possible**: Linux provisioning is fully automated
3. **Clear documentation of limitations**: Windows IPN issue is documented, not hidden
4. **Graceful degradation**: When automation fails, provide clear manual steps
5. **Security**: Key-based SSH, encrypted WireGuard mesh, no password storage
