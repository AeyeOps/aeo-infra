# Lessons Learned

Key insights from implementing the three-node mesh network.

## 1. WSL2 Mirrored Networking Shares Port Space

**Lesson:** With WSL2 mirrored networking enabled, WSL and Windows share the same network namespace. Both cannot bind to the same port.

**Implication:** If Windows OpenSSH Server runs on port 22, WSL SSH must use a different port.

**Best practice:** 
- Windows SSH: Port 22
- WSL SSH: Port 2222
- Update all SSH configs to use correct ports

## 2. Windows Credentials Are Session-Type Isolated

**Lesson:** Windows Credential Manager stores credentials per "logon type". Credentials saved via RDP are not visible to SSH sessions, and vice versa.

**Implication:** 
- `cmdkey /add` from SSH session → Only visible to SSH sessions
- `cmdkey /add` from RDP/console → Only visible to interactive sessions
- Scheduled tasks run in yet another isolated context

**Best practice:** Always store credentials from the same session type that will use them. For drive mappings, use interactive (console/RDP) sessions.

## 3. Scheduled Tasks Run in Different Credential Context

**Lesson:** Scheduled tasks, even when "Run As" a specific user, operate in an isolated credential context that doesn't have access to the user's stored credentials.

**Implication:** `net use` in a scheduled task can't use credentials stored via `cmdkey`.

**Best practice:** Use Startup folder scripts instead. They run in the user's actual login session with full credential access.

## 4. Startup Folder vs Scheduled Tasks

| Aspect | Startup Folder | Scheduled Task |
|--------|----------------|----------------|
| Credential access | Full user context | Isolated context |
| Runs on login | Yes | Configurable |
| Admin required | No | Sometimes |
| Reliability | High | Can fail silently |

**Best practice:** For user-context operations (drive mapping, credential-dependent tasks), prefer Startup folder.

## 5. Tailscale IPs May Differ from Local IPs

**Lesson:** mDNS hostnames (*.local) resolve to LAN IPs, which may be firewalled differently than Tailscale IPs.

**Example:**
- `windows-host.local` → 192.168.1.100 (LAN, RDP blocked)
- Tailscale IP → 100.64.0.4 (mesh, RDP allowed)

**Best practice:** Use Tailscale IPs in SSH configs for consistency. Don't rely on mDNS for mesh connectivity.

## 6. Firewall Rules Need Tailscale Network

**Lesson:** When adding firewall rules for mesh access, the source network should be the Tailscale CGNAT range (100.64.0.0/10), not specific IPs.

**Best practice:**
```bash
# Linux (ufw)
sudo ufw allow from 100.64.0.0/10 to any port 445

# Windows PowerShell
New-NetFirewallRule -DisplayName "Service from Tailscale" `
    -Direction Inbound -RemoteAddress 100.64.0.0/10 `
    -LocalPort 445 -Protocol TCP -Action Allow
```

## 7. SSH Config Aliases Prevent Errors

**Lesson:** Using SSH config aliases (`ssh windows` vs `ssh 100.64.0.4 -p 22`) reduces errors and makes configs portable.

**Best practice:** Define aliases in `~/.ssh/config` on every machine:
```
Host friendly-name
    HostName 100.64.x.x
    Port 22
    User myuser
```

## 8. Document Infrastructure for AI Agents

**Lesson:** AI coding assistants will "helpfully" modify configs while troubleshooting, potentially breaking working infrastructure.

**Best practice:** Create `AGENTS.md` or similar documentation with clear "DO NOT MODIFY" warnings and list exactly what the infrastructure components are.

## 9. Samba and System Passwords Are Separate

**Lesson:** Samba maintains its own password database. The Samba password for a user can be (and often should be) different from their system login password.

**Command:** `sudo smbpasswd -a username`

## 10. NFS Works Better for Linux-to-Linux

**Lesson:** While Samba is required for Windows access, NFS is simpler and more performant for Linux-to-Linux (including WSL) file sharing.

**Best practice:** Use both:
- Samba for Windows clients
- NFS for Linux/WSL clients

## 11. Test from the Right Context

**Lesson:** When debugging connectivity issues, ensure you're testing from the same context that will be used in production.

**Anti-pattern:** Testing drive mapping from PowerShell admin prompt, then wondering why it doesn't work for the normal user.

**Best practice:** Test from the exact environment (user session, elevation level, connection type) that will be used.
