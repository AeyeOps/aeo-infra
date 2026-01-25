# Legacy SSHFS Scripts

These scripts implemented the previous SSHFS-based architecture where sfspark1 was the central file server and other machines mounted `/opt/shared` over the network.

**Reason for replacement:** SSHFS has a single point of failure (sfspark1 must be online), doesn't work well over the internet, and requires manual reconnection after network interruptions.

**New architecture:** Tailscale (mesh VPN) + Syncthing (distributed file sync) provides true peer-to-peer replication with no single point of failure.

## Archived Scripts

| Script | Original Purpose |
|--------|------------------|
| `setup-ssh-server.sh` | Configure SSH on sfspark1 |
| `setup-sshfs-client.sh` | Mount SSHFS on WSL2 client |
| `setup-openssh-windows.sh` | Enable OpenSSH Server on Windows |
| `setup-openssh-windows.ps1` | PowerShell companion for Windows SSH |
| `setup-sshfs-windows.sh` | Configure SSH keys for SSHFS-Win |
| `setup-sshfs-windows.ps1` | Install SSHFS-Win on Windows |
| `reconnect.sh` | Reconnect dropped SSHFS mounts |

## Rollback Procedure

If needed, restore SSHFS by:

1. Stop Syncthing on all nodes
2. Run the archived scripts in order:
   - `setup-ssh-server.sh` on sfspark1
   - `setup-sshfs-client.sh` on WSL2
   - `setup-openssh-windows.sh` + `setup-sshfs-windows.sh` from WSL2 for Windows
3. Mount manually: `sshfs steve@sfspark1.local:/opt/shared /opt/shared`

Note: Tailscale can remain active (it doesn't interfere with SSHFS).
