---
description: Check mesh network status and connectivity
argument-hint: [host]
allowed-tools: ["Bash", "Read"]
---

# /mesh-status

Check the status of the mesh network, including Headscale server, connected nodes, and SSH connectivity.

## Usage

```
/mesh-status           # Full status check
/mesh-status windows   # Check specific host
```

## What This Command Does

1. **Check Headscale server** (if on sfspark1)
2. **List connected nodes** with their Tailscale IPs
3. **Test SSH connectivity** to known hosts
4. **Report Syncthing status** (if applicable)

## Procedure

### Step 1: Identify Current Machine

Run `hostname` to determine the current machine context.

### Step 2: Check Headscale Status (sfspark1 only)

If on sfspark1, check the Headscale server:

```bash
sudo systemctl status headscale --no-pager
sudo headscale nodes list
```

### Step 3: Check Local Tailscale

```bash
tailscale status
tailscale ip -4
```

### Step 4: Test SSH Connectivity

For each known mesh host, test SSH:

```bash
# Windows (port 22)
ssh -o BatchMode=yes -o ConnectTimeout=5 steve@office-one.local -p 22 "echo ok" 2>&1

# WSL (port 2222)
ssh -o BatchMode=yes -o ConnectTimeout=5 steve@office-one.local -p 2222 "echo ok" 2>&1
```

### Step 5: Check Remote Tailscale Status

For reachable hosts:

```bash
# Linux/WSL
ssh steve@office-one.local -p 2222 "tailscale status"

# Windows
ssh steve@office-one.local -p 22 "powershell -Command \"& 'C:\\Program Files\\Tailscale\\tailscale.exe' status\""
```

### Step 6: Report Summary

Present findings as a status table:

| Host | SSH | Tailscale | IP |
|------|-----|-----------|-----|
| sfspark1 | N/A (local) | Online | 100.64.0.1 |
| windows | OK/Failed | Online/Offline | 100.64.0.2 |
| wsl | OK/Failed | Online/Offline | 100.64.0.3 |

## Alternative: Use mesh CLI

The mesh CLI has a built-in status command:

```bash
mesh remote status steve@office-one.local --port 22
mesh remote status steve@office-one.local --port 2222
```

Or the local status check:

```bash
mesh status --verbose
```

## Troubleshooting Common Issues

### Headscale not running
```bash
sudo systemctl start headscale
sudo systemctl status headscale
```

### Tailscale shows "Logged out"
- On Linux: Re-run `tailscale up` with auth key
- On Windows: Run the `join-mesh.ps1` script in interactive session

### SSH connection refused
- Check SSH service is running
- Verify firewall allows the port
- Confirm correct port (22 for Windows, 2222 for WSL)

### mDNS resolution failing
Use IP addresses instead of `.local` hostnames, especially in Docker environments.
