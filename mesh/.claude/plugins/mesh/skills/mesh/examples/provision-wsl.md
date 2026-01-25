# Example: Provisioning a WSL2 Host

This walkthrough demonstrates provisioning a WSL2 instance to join the MeSH network.

## Scenario

**Target:** WSL2 Ubuntu on office-one at port 2222
**User:** steve
**Starting point:** SSH key auth configured, but sudo requires password

## Step 1: Prepare for Passwordless Provisioning

WSL2 typically requires password for sudo. Prepare the host first:

```bash
# From sfspark1
mesh remote prepare steve@office-one.local --port 2222
```

**Interactive session opens:**

```
═══ Preparing steve@office-one.local:2222 ═══

Configuring passwordless sudo for mesh commands...
(You may be prompted for your password)

[sudo] password for steve: ********
✓ Passwordless sudo configured for mesh commands
You can now run: mesh remote provision steve@office-one.local
```

This creates `/etc/sudoers.d/mesh-provisioning` allowing passwordless sudo for:
- `/usr/bin/tailscale*`
- `/usr/bin/apt-get update/install`
- `/bin/systemctl * tailscaled*`

## Step 2: Run Provisioning

```bash
mesh remote provision steve@office-one.local --port 2222
```

**Expected output:**

```
═══ Provisioning steve@office-one.local:2222 ═══

Testing SSH connectivity...
✓ SSH connection successful

Detecting remote OS...
✓ Detected OS: linux

Generating Headscale auth key...
✓ Auth key generated

Installing Tailscale on Linux...
Downloading and running Tailscale installer...
✓ Tailscale installed

Connecting to mesh network...
✓ Connected to mesh network
Tailscale IP: 100.64.0.3

Installing Syncthing...
✓ Syncthing installed

═══ Provisioning Complete ═══
✓ steve@office-one.local is now part of the mesh network
```

## Step 3: Verify Connection

From sfspark1:

```bash
# List nodes
sudo headscale nodes list

ID | Hostname    | Name        | IPv4       | Online
1  | sfspark1    | sfspark1    | 100.64.0.1 | true
3  | office-one  | office-one  | 100.64.0.3 | true

# Test connectivity
tailscale ping office-one
pong from office-one (100.64.0.3) via 10.0.0.45:41642 in 3ms
```

From WSL:

```bash
# Check status
tailscale status

# Health check
100.64.0.1      sfspark1        linux   -
                office-one      linux   -

# Ping the server
tailscale ping sfspark1
pong from sfspark1 (100.64.0.1) via 10.0.0.56:41641 in 2ms
```

## Why WSL Uses Port 2222

WSL2 and Windows share the same network namespace. Both can run SSH servers:
- Windows OpenSSH Server: port 22
- WSL SSH Server: port 2222

This avoids the port conflict.

### Configuring WSL SSH on Port 2222

If not already configured:

```bash
# In WSL
sudo sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### Windows Firewall Rule

Windows needs to allow the port:

```powershell
# On Windows
New-NetFirewallRule -DisplayName "WSL SSH" -Direction Inbound -LocalPort 2222 -Protocol TCP -Action Allow
```

## Difference from Windows Provisioning

Unlike Windows, WSL provisioning is **fully automated**:

| Step | Windows | WSL |
|------|---------|-----|
| Tailscale install | Via winget | Via curl script |
| Connect to mesh | Manual script required | Automated via SSH |
| Syncthing | Not installed | Installed automatically |

The reason: WSL runs a proper Linux environment without Windows session isolation issues.

## Troubleshooting

### "sudo requires password"

The `mesh remote prepare` step was skipped or failed:

```bash
mesh remote prepare steve@office-one.local --port 2222
```

### SSH connection refused

Check WSL SSH is running and on port 2222:

```bash
# In WSL
sudo systemctl status ssh
grep Port /etc/ssh/sshd_config
```

### Tailscale installation failed

Try installing manually:

```bash
# In WSL
curl -fsSL https://tailscale.com/install.sh | sudo sh
```

### Connection timeout

If `tailscale up` times out:
1. Check Headscale server is reachable
2. Verify the server URL is correct
3. Try with IP instead of hostname

## Next Steps

After successful provisioning:
1. Configure Syncthing shared folders
2. Test bidirectional connectivity to all mesh nodes
3. Set up any services that need mesh network access
