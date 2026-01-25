# Multi-Host SSH Configuration

MeSH uses SSH for remote provisioning. This document covers the SSH configuration patterns for the mesh environment, including key-based authentication, port management, and troubleshooting.

## Overview

The mesh environment requires SSH access to multiple hosts with different characteristics:
- Different operating systems (Windows, Linux/WSL)
- Different ports (to avoid conflicts)
- Different authentication requirements (admin vs standard user)
- Different SSH server implementations (OpenSSH on Linux, Windows OpenSSH Server)

Understanding these differences is essential for reliable provisioning.

## Host Configuration

The mesh environment typically includes these hosts:

| Host | Port | User | OS | SSH Server | Description |
|------|------|------|-----|------------|-------------|
| sfspark1 | 22 | steve | Ubuntu 24.04 | OpenSSH | Headscale server |
| windows | 22 | steve | Windows 11 | Windows OpenSSH | Windows desktop |
| wsl | 2222 | steve | Ubuntu 24.04 | OpenSSH | WSL2 instance |
| windows-vm | 2222 | Docker | Windows 11 | Windows OpenSSH | Test VM in Docker |

### Why Different Ports?

Windows and WSL2 share the same network namespace - they have the same IP address as seen from the network. If both run SSH servers, they can't both use port 22. The convention:
- **Port 22**: Windows native SSH or the "primary" SSH server
- **Port 2222**: WSL2 SSH, secondary SSH, or test environments

### Sample ~/.ssh/config

A complete SSH config file for the mesh environment:

```
# Primary Headscale server
Host sfspark1
    HostName sfspark1.local
    Port 22
    User steve
    IdentityFile ~/.ssh/id_ed25519

# Windows native
Host windows
    HostName office-one.local
    Port 22
    User steve
    IdentityFile ~/.ssh/id_ed25519

# WSL2 on the same machine
Host wsl
    HostName office-one.local
    Port 2222
    User steve
    IdentityFile ~/.ssh/id_ed25519

# Docker Windows VM for testing
Host windows-vm
    HostName localhost
    Port 2222
    User Docker
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no  # VM is ephemeral, host key changes often

# Wildcard for mesh hosts (optional)
Host *.local
    User steve
    IdentityFile ~/.ssh/id_ed25519
    ConnectTimeout 10
```

### Config File Best Practices

1. **Use mDNS hostnames** (`.local`) for LAN hosts - they resolve via multicast DNS
2. **Specify IdentityFile** explicitly to avoid key confusion
3. **Use Host aliases** for convenience (`ssh windows` instead of `ssh -p 22 steve@office-one.local`)
4. **Set ConnectTimeout** for faster failure detection on unreachable hosts

## Non-Interactive SSH Options

For automated provisioning, SSH must work without interactive prompts:

```python
SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=10",
    "-o", "StrictHostKeyChecking=accept-new",
]
```

### BatchMode=yes

Disables:
- Password prompts
- Passphrase prompts
- Host key confirmation

**Implication**: Key-based authentication must be configured.

### ConnectTimeout=10

Fail fast if host is unreachable. Default would wait much longer.

### StrictHostKeyChecking=accept-new

- Accept new host keys automatically (first connection)
- Still reject changed keys (prevents MITM)
- Alternative: `StrictHostKeyChecking=no` (less secure)

## Key-Based Authentication

### Linux/WSL Setup

```bash
# Generate key if needed
ssh-keygen -t ed25519

# Copy to remote
ssh-copy-id -p 22 steve@office-one.local   # Windows
ssh-copy-id -p 2222 steve@office-one.local # WSL
```

### Windows OpenSSH Setup

Windows stores admin keys in a different location:

```powershell
# Standard users: ~/.ssh/authorized_keys
# Administrators: C:\ProgramData\ssh\administrators_authorized_keys

# The file needs specific ACL permissions
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /grant "SYSTEM:F"
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /grant "Administrators:F"
```

For Docker Windows VMs, this is handled by `install.bat` during first boot.

## Port Selection

### Why WSL Uses Port 2222

WSL and Windows share the same network namespace. If both run SSH servers:
- Windows OpenSSH Server: port 22
- WSL SSH Server: port 2222

This avoids the conflict and allows both to be reachable.

### Configuring WSL SSH Port

```bash
# /etc/ssh/sshd_config
Port 2222
```

Then restart: `sudo systemctl restart ssh`

### Windows Firewall

Windows needs a firewall rule for WSL's SSH port:

```powershell
New-NetFirewallRule -DisplayName "WSL SSH" `
    -Direction Inbound -LocalPort 2222 `
    -Protocol TCP -Action Allow
```

## SSH Command Execution Pattern

The provisioning code wraps SSH commands:

```python
def ssh_run(host: str, port: int, cmd: str, timeout: int = 120) -> tuple[bool, str]:
    ssh_cmd = ["ssh"] + SSH_OPTS + ["-p", str(port), host, cmd]
    result = subprocess.run(
        ssh_cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result.returncode == 0, result.stdout + result.stderr
```

Usage:
```python
success, output = ssh_run("steve@office-one.local", 2222, "uname -a")
```

## OS Detection via SSH

The provisioning detects remote OS type:

```python
def detect_remote_os(host: str, port: int) -> str | None:
    # Try uname (Linux/macOS/MSYS)
    success, output = ssh_run(host, port, "uname -s")
    if success:
        if "linux" in output.lower():
            return "linux"
        if "msys" in output.lower():
            return "windows"  # Git Bash

    # Try Windows-specific
    success, output = ssh_run(host, port, "echo %OS%")
    if success and "windows" in output.lower():
        return "windows"

    # Fallback to PowerShell
    success, output = ssh_run(host, port, 'powershell -Command "$env:OS"')
    if success and "windows" in output.lower():
        return "windows"

    return None
```

## Troubleshooting

### Connection Refused

```
ssh: connect to host office-one.local port 22: Connection refused
```

**Causes:**
- SSH server not running
- Firewall blocking port
- Wrong port number

**Debug:**
```bash
# Check if port is open
nc -zv office-one.local 22

# Check SSH server status (on target)
sudo systemctl status sshd
```

### Host Key Changed

```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

**Cause:** Host was reinstalled or key regenerated.

**Fix:**
```bash
ssh-keygen -R office-one.local
```

### Permission Denied

```
Permission denied (publickey).
```

**Causes:**
- Key not in authorized_keys
- Wrong file permissions
- Windows admin key location issue

**Debug:**
```bash
ssh -v steve@office-one.local  # Verbose mode shows auth attempts
```

### Timeout

```
ssh: connect to host office-one.local port 22: Connection timed out
```

**Causes:**
- Host unreachable
- Firewall dropping packets (vs rejecting)
- Wrong hostname/IP

**Debug:**
```bash
ping office-one.local
traceroute office-one.local
```

## mDNS Hostname Resolution

The mesh uses `.local` hostnames via mDNS (Bonjour/Avahi):
- `sfspark1.local`
- `office-one.local`

### How mDNS Works

mDNS (multicast DNS) resolves `.local` hostnames on the local network:
1. Client sends multicast query to `224.0.0.251:5353`
2. Target host responds with its IP address
3. No central DNS server required

### mDNS on Different Platforms

| Platform | Implementation | Status |
|----------|---------------|--------|
| macOS | Built-in (Bonjour) | Works by default |
| Linux | Avahi + libnss-mdns | Usually works, may need `avahi-daemon` |
| Windows | Built-in (since Win 10 1809) | Works for `.local` resolution |
| WSL2 | Inherits from Windows | Works via Windows resolver |
| Docker | No mDNS support | Use IP addresses |

### Docker mDNS Limitation

Docker containers run in an isolated network namespace and typically can't resolve mDNS:

```bash
# This fails inside Docker
mesh remote provision Docker@localhost --server http://sfspark1.local:8080
# Error: Could not resolve host: sfspark1.local

# Use IP address instead
mesh remote provision Docker@localhost --server http://10.0.0.56:8080
```

**Workarounds for Docker:**
1. Use IP addresses directly (recommended)
2. Add entries to container's `/etc/hosts`
3. Use Docker's `--add-host` flag
4. Run with `--network=host` (not always possible)

### Troubleshooting mDNS

```bash
# Check if Avahi is running (Linux)
systemctl status avahi-daemon

# Test mDNS resolution
avahi-resolve -n sfspark1.local
# or
getent hosts sfspark1.local

# On macOS
dns-sd -G v4 sfspark1.local

# On Windows
ping sfspark1.local
```

## Security Considerations

### Key Management

1. **Use Ed25519 keys** - Modern, fast, small, secure
2. **Separate keys per machine** (optional) - Limits blast radius of compromise
3. **Protect private keys** - `chmod 600 ~/.ssh/id_ed25519`
4. **Use ssh-agent** - Avoid typing passphrase repeatedly

### SSH Agent Forwarding

Enable agent forwarding to use local keys on remote machines:

```
Host sfspark1
    ForwardAgent yes
```

**Caution:** Only enable agent forwarding to trusted hosts - a compromised host could use your agent.

### Known Hosts Management

The `~/.ssh/known_hosts` file tracks server fingerprints:

```bash
# View known hosts
cat ~/.ssh/known_hosts

# Remove a host (after reinstall)
ssh-keygen -R office-one.local

# Add a host manually
ssh-keyscan -p 22 office-one.local >> ~/.ssh/known_hosts
```

### SSH Config Security

Sensitive options for improved security:

```
Host *
    HashKnownHosts yes           # Don't reveal hostnames in known_hosts
    AddKeysToAgent yes           # Add keys to agent automatically
    IdentitiesOnly yes           # Only use specified keys, not all in agent
    PasswordAuthentication no    # Disable password auth entirely
```

## Advanced Patterns

### ProxyJump for Multi-Hop Access

Access internal machines through a bastion:

```
Host internal-machine
    HostName 192.168.1.100
    ProxyJump sfspark1
    User steve
```

### SSH Multiplexing

Reuse connections for faster subsequent commands:

```
Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 600
```

Create the socket directory: `mkdir -p ~/.ssh/sockets`

### LocalCommand on Connect

Run commands automatically when connecting:

```
Host sfspark1
    PermitLocalCommand yes
    LocalCommand echo "Connected to sfspark1 at $(date)" >> ~/.ssh/connect.log
```

## Testing SSH Configuration

### Verify Configuration

```bash
# Test SSH config syntax
ssh -G hostname

# Test connection with verbose output
ssh -v steve@office-one.local

# Very verbose (debugging)
ssh -vvv steve@office-one.local
```

### Verify Key Authentication

```bash
# List available keys
ssh-add -l

# Test authentication (don't open shell)
ssh -T steve@office-one.local
```

## Related

- `./windows-ipn-limitation.md` - Why Windows SSH can't complete Tailscale connection
- `./ssh-powershell-escaping.md` - Running PowerShell via SSH
- `../examples/provision-wsl.md` - WSL-specific setup
- `../references/port-reference.md` - Complete port assignments
