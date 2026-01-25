# Mesh Remote Provisioning - Testing Gaps

Findings from testing `mesh remote` commands against fresh Windows VM.

## Test Results Summary

**Final Status:** SUCCESS - Multiple nodes joined mesh network

```
Headscale Nodes:
- sfspark1        (100.64.0.1) - Linux   - online  (server)
- win-im3jegkaef3 (100.64.0.2) - Windows - online  (Docker Windows VM)
- office-one      (100.64.0.3) - Linux   - online  (WSL2)
```

Bidirectional mesh connectivity verified (ping works all directions).

## Gap #1: Fresh Windows VMs Have No SSH Access

**Problem:** The `mesh remote provision` command requires SSH connectivity, but fresh Windows 11 installations don't have OpenSSH Server enabled by default.

**Impact:** Cannot provision fresh Windows machines without manual intervention.

**Current Workaround:**
1. Access VM via noVNC (http://localhost:8006)
2. Run PowerShell as Administrator
3. Execute: `\\shared\enable-ssh.ps1` (or paste commands manually)

**Potential Solutions:**

### Option A: Custom Windows Image with SSH Pre-enabled
Modify the dockurr/windows unattend.xml to enable SSH during FirstLogonCommands:
```xml
<SynchronousCommand wcm:action="add">
  <Order>12</Order>
  <CommandLine>powershell.exe -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service -Name sshd -StartupType Automatic"</CommandLine>
  <Description>Enable OpenSSH Server</Description>
</SynchronousCommand>
```

### Option B: WinRM Bootstrap Command
Add `mesh remote bootstrap-windows` that uses WinRM (also not enabled by default, but can be enabled via netsh).

### Option C: Document Manual Pre-requisite
Document that Windows machines need SSH enabled before `mesh remote provision` can work.

**Recommendation:** Option A for CI/test VMs, Option C for real-world deployments.

**FIX IMPLEMENTED:**
- Created `/opt/dev/aeo/aeo-ci/targets/windows-vm/oem/install.bat` - enables SSH at first boot
- Updated `start.sh` to:
  - Mount `/oem` volume (triggers automatic script execution)
  - Map SSH port (22 -> 2222)
  - Map RDP port (3389 -> 3389)
  - Add NET_ADMIN capability for networking

---

## Gap #2: Windows Tailscale IPN Issue (FUNDAMENTAL LIMITATION)

**Problem:** The Tailscale CLI via SSH cannot communicate with the Tailscale service because they run in different Windows sessions. This is a fundamental Windows architecture limitation.

**Root Cause:** Windows session isolation prevents SSH session processes from communicating with services running in Session 0 or interactive sessions via named pipes.

**Impact:** `mesh remote provision` cannot complete Windows Tailscale connection via SSH.

**Workarounds Attempted:**
- Service restart before connect: ❌ Doesn't help
- Retry logic: ❌ Doesn't help
- Task Scheduler (SYSTEM): ❌ Same session isolation issue
- Task Scheduler (Interactive): ❌ Still isolated
- WMI/CIM process creation: ❌ Same issue
- Registry configuration (LoginURL, AuthKey, UnattendedMode): ❌ Read but doesn't trigger connection
- Fresh install with MSI auth key parameters: ❌ State persists as logged out
- Clearing state files: ❌ Doesn't help
- PsExec with -s and -i flags: ❌ Same isolation

**Technical Details:**
- Tailscale uses named pipe `\\.\pipe\ProtectedPrefix\LocalService\tailscale-ipn` for IPC
- This pipe is protected by Windows session isolation
- SSH sessions, scheduled tasks, and WMI processes cannot access it
- Registry settings are read but only provide credentials - they don't initiate connection
- The `loggedout=true` state persists across reinstalls

**Solution:** The `mesh remote provision` command now automatically:
1. Detects the IPN issue after connection attempts fail
2. Creates a PowerShell script at `C:\temp\join-mesh.ps1` with the correct auth key
3. Displays instructions for the user to run the script

**User Action Required:**
```powershell
powershell -ExecutionPolicy Bypass -File C:\temp\join-mesh.ps1
```
Or right-click the file and select "Run with PowerShell".

**Status:** PARTIALLY AUTOMATED - Script is created automatically, user runs it manually in interactive session. This is the best possible outcome given Windows session isolation constraints.

---

## Gap #3: sudo Password Required for Linux

**Problem:** Non-interactive SSH (BatchMode=yes) can't provide sudo password.

**Impact:** `mesh remote provision` fails on Linux hosts that require password for sudo.

**Current Handling:** Added `mesh remote prepare` command to configure passwordless sudo.

**One-Time Manual Setup Required:**
```bash
# SSH to the target machine interactively
ssh user@host

# Add passwordless sudo for tailscale
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/tailscale*" | sudo tee /etc/sudoers.d/tailscale
```

Or run `mesh remote prepare` which will prompt for password once.

**Status:** PARTIALLY RESOLVED - requires one-time password entry.

---

## Test Environment

- **VM:** dockurr/windows (Docker-based Windows 11 ARM64)
- **Host:** sfspark1 (GB10 - Grace ARM + Blackwell GPU)
- **Access:** noVNC at http://localhost:8006, SSH mapped to localhost:2222
- **Shared folder:** `/opt/dev/aeo/aeo-ci/targets/windows-vm/sync` → `\\shared` in VM
- **User:** `Docker` (empty password, Administrator)

---

## Gap #4: SSH Key Setup for Windows VMs

**Problem:** Even with SSH Server enabled, key-based authentication requires:
1. The public key to be available in the shared folder
2. Proper ACL permissions on `C:\ProgramData\ssh\administrators_authorized_keys`

**Impact:** First-time SSH access requires either manual key setup or rebuild.

**Current Handling:**
- Updated `install.bat` to auto-configure keys from `\\shared\authorized_keys`
- Created `setup-ssh-key.ps1` for manual setup via noVNC on existing VMs

**Status:** RESOLVED for new VMs (included in install.bat). Existing VMs need one-time manual setup.

---

## Gap #5: Docker VM Cannot Resolve mDNS Hostnames

**Problem:** When running `mesh remote provision` against a Windows VM in Docker, the default server URL `http://sfspark1.local:8080` cannot be resolved because Docker networks don't support mDNS.

**Impact:** Tailscale fails to connect with no clear error (just times out).

**Workaround:** Use IP address instead of hostname:
```bash
mesh remote provision Docker@localhost --port 2222 --server http://10.0.0.56:8080
```

**Potential Fix:** Update mesh CLI to:
1. Check if server URL resolves before passing to Tailscale
2. Auto-detect and use IP if hostname fails
3. Provide clearer error message about DNS resolution

**Status:** Documented - use IP address for Docker VMs.

---

## Gap #6: winget msstore Certificate Error

**Problem:** On fresh Windows 11, `winget install` fails with "server certificate did not match" error for msstore source.

**Impact:** Tailscale installation fails silently.

**Fix Implemented:** Added `--source winget` to avoid msstore source.

**Status:** RESOLVED in remote.py.

---

## Files Created During Testing

- `/opt/dev/aeo/aeo-ci/targets/windows-vm/oem/install.bat` - Auto-enables SSH and configures keys
- `/opt/dev/aeo/aeo-ci/targets/windows-vm/sync/enable-ssh.ps1` - Script to enable OpenSSH Server (legacy)
- `/opt/dev/aeo/aeo-ci/targets/windows-vm/sync/authorized_keys` - SSH public key for key-based auth
- `/opt/dev/aeo/aeo-ci/targets/windows-vm/sync/setup-ssh-key.ps1` - Manual key setup for existing VMs
