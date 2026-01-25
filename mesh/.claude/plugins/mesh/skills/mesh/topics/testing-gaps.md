# Testing Gaps and Resolutions

During MeSH development, testing against a fresh Windows VM revealed several gaps. This document summarizes each gap and its resolution.

## Summary

| Gap | Status | Resolution |
|-----|--------|------------|
| #1: Fresh Windows no SSH | RESOLVED | OEM install.bat enables SSH at first boot |
| #2: Windows IPN issue | PARTIALLY AUTOMATED | Script created automatically, run manually |
| #3: Linux sudo password | RESOLVED | `mesh remote prepare` command |
| #4: Windows SSH key setup | RESOLVED | install.bat configures keys |
| #5: Docker mDNS resolution | DOCUMENTED | Use IP addresses |
| #6: winget msstore cert error | RESOLVED | `--source winget` flag |

## Gap #1: Fresh Windows VMs Have No SSH Access

### Problem

Fresh Windows 11 installations don't have OpenSSH Server enabled. The `mesh remote provision` command requires SSH connectivity.

### Impact

Cannot provision fresh Windows machines without manual intervention.

### Resolution

**For new VMs** (Docker Windows):
Created `oem/install.bat` that runs during Windows FirstLogonCommands:
- Enables OpenSSH Server capability
- Starts sshd service
- Sets to automatic startup
- Configures SSH key from shared folder

**For existing machines:**
1. Access via RDP/noVNC
2. Run PowerShell as Administrator
3. Execute enabling commands or use provided `enable-ssh.ps1`

## Gap #2: Windows Tailscale IPN Issue (FUNDAMENTAL)

### Problem

Windows session isolation prevents SSH sessions from communicating with the Tailscale service via named pipe.

### Impact

`mesh remote provision` cannot complete Windows Tailscale connection via SSH.

### Resolution

**Status: PARTIALLY AUTOMATED**

The provisioning command now:
1. Detects failure after connection attempts
2. Creates `C:\temp\join-mesh.ps1` with correct auth key
3. Instructs user to run script in interactive session

See `./windows-ipn-limitation.md` for full technical details.

## Gap #3: sudo Password Required for Linux

### Problem

Non-interactive SSH (`BatchMode=yes`) cannot provide sudo password.

### Impact

`mesh remote provision` fails on Linux hosts requiring password for sudo.

### Resolution

**Added `mesh remote prepare` command:**

```bash
mesh remote prepare steve@office-one.local --port 2222
```

This command:
1. Uses interactive SSH (prompts for password once)
2. Creates `/etc/sudoers.d/mesh-provisioning`
3. Allows passwordless sudo for:
   - `/usr/bin/tailscale*`
   - `/usr/bin/apt-get update/install`
   - `/bin/systemctl * tailscaled*`

After running once, subsequent provisioning works non-interactively.

## Gap #4: SSH Key Setup for Windows VMs

### Problem

Even with SSH Server enabled, key-based authentication requires:
1. Public key available on the machine
2. Proper ACL permissions on `administrators_authorized_keys`

### Impact

First-time SSH access requires either manual key setup or VM rebuild.

### Resolution

**For new VMs:**
Updated `install.bat` to:
1. Read public key from `\\shared\authorized_keys`
2. Write to `C:\ProgramData\ssh\administrators_authorized_keys`
3. Set correct NTFS ACLs (SYSTEM:F, Administrators:F)

**For existing VMs:**
Created `setup-ssh-key.ps1` for manual execution via noVNC.

## Gap #5: Docker VM Cannot Resolve mDNS Hostnames

### Problem

Docker networks don't support mDNS. When provisioning a Windows VM in Docker, `http://sfspark1.local:8080` cannot be resolved.

### Impact

Tailscale connection fails silently (timeout).

### Resolution

**Status: DOCUMENTED**

Use IP address instead of hostname:

```bash
# Instead of
mesh remote provision Docker@localhost --port 2222 --server http://sfspark1.local:8080

# Use
mesh remote provision Docker@localhost --port 2222 --server http://10.0.0.56:8080
```

**Potential future enhancement:** Auto-detect DNS resolution failure and suggest IP.

## Gap #6: winget msstore Certificate Error

### Problem

On fresh Windows 11, `winget install` fails with "server certificate did not match" error when using msstore source.

### Impact

Tailscale installation fails silently.

### Resolution

**Fixed in remote.py:**

Added `--source winget` to avoid the msstore source:

```python
install_cmd = (
    'powershell -Command "winget install --id Tailscale.Tailscale '
    '--source winget --accept-source-agreements --accept-package-agreements --silent"'
)
```

## Test Environment Details

**VM:** dockurr/windows (Docker-based Windows 11 ARM64)
**Host:** sfspark1 (GB10 - Grace ARM + Blackwell GPU)
**Access:**
- noVNC at http://localhost:8006
- SSH mapped to localhost:2222
**Shared folder:** `/opt/dev/aeo/aeo-ci/targets/windows-vm/sync` → `\\shared` in VM
**User:** `Docker` (empty password, Administrator)

## Files Created During Testing

| File | Purpose |
|------|---------|
| `oem/install.bat` | Auto-enables SSH and configures keys at first boot |
| `sync/enable-ssh.ps1` | Manual SSH enablement (legacy) |
| `sync/authorized_keys` | SSH public key for key-based auth |
| `sync/setup-ssh-key.ps1` | Manual key setup for existing VMs |

## Lessons Learned

1. **Windows session isolation is fundamental** - Don't fight it, work around it
2. **Test against fresh installs** - Many assumptions fail on clean systems
3. **Document limitations clearly** - Users need to know what's automated vs manual
4. **Provide clear fallback instructions** - When automation fails, guide users
5. **Docker != real hardware** - mDNS, GPU passthrough, etc. may not work

## Related

- `./windows-ipn-limitation.md` - Deep dive on Gap #2
- `share-tools/docs/TESTING-GAPS.md` - Original gap documentation
- `../examples/provision-windows.md` - Current workflow with gaps addressed
