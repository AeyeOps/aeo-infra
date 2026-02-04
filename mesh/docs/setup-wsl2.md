# WSL2 Mesh Setup Guide

WSL2 on a Headscale mesh requires a different approach than native Linux nodes.
This guide explains the constraints and the working configuration.

## Why WSL2 Cannot Run Its Own Tailscale

WSL2 in mirrored networking mode (`networkingMode=mirrored`) shares the Windows
host's network stack and IP addresses. This creates fundamental conflicts with
running an independent Tailscale instance inside WSL2:

1. **Tunnel-in-tunnel failure.** Tailscale packets from WSL2 would need to
   traverse the Windows host's Tailscale WireGuard tunnel. WireGuard cannot
   encapsulate its own packets -- the MTU math does not work and the encrypted
   payloads cannot fit inside the tunnel.

2. **IP collision.** Both WSL2 and the Windows host share IP addresses in
   mirrored mode. Two Tailscale instances cannot claim the same 100.64.x.x
   address, and the coordination server (Headscale) cannot route to two nodes
   at a single endpoint.

3. **No TUN device.** The WSL2 kernel often lacks `CONFIG_TUN`, so `tailscaled`
   cannot create `/dev/net/tun`. Even with systemd support in recent WSL2
   builds, the TUN device is frequently missing.

4. **No routing control.** WSL2 does not control the host's routing tables.
   `tailscaled` inside WSL2 cannot manipulate the routes it needs to function
   as a mesh node.

5. **Asymmetric routing.** Inbound Tailscale traffic arrives via the Windows
   host's tunnel, but responses from WSL2 may exit through a different path,
   breaking TCP connections.

These are architectural constraints, not bugs. Tailscale officially recommends
running only on the Windows host, not inside WSL2.

## The Working Model

WSL2 piggybacks on the Windows host's Tailscale connection:

```
Remote mesh node (e.g., sfspark1 @ 100.64.0.1)
    |
    | WireGuard tunnel
    v
Windows host Tailscale (100.64.0.3)
    |
    | Mirrored network stack (shared IPs)
    v
WSL2 instance (sees 100.64.0.3 as its own)
```

**Outbound from WSL2:** Traffic to Tailscale IPs (100.64.x.x) leaves through
the shared network stack, hits the Windows Tailscale routing table, and enters
the WireGuard tunnel. This works transparently.

**Inbound to WSL2:** Traffic arriving at the Windows Tailscale IP on a port
that WSL2 has bound will reach WSL2 through the mirrored stack. Services
listening in WSL2 are reachable from the mesh, provided the Windows host is
not also binding the same port.

## Prerequisites

- Windows 10/11 with WSL2 enabled
- Tailscale (or Headscale client) installed and connected **on the Windows host**
- WSL2 configured with mirrored networking:

```ini
# %USERPROFILE%\.wslconfig
[wsl2]
networkingMode=mirrored
```

- NFS client packages inside WSL2

## Setup: NFS Shared Directory

The mesh uses NFSv4 to share `/opt/shared` from the NFS server node (sfspark1).
WSL2 mounts it as an NFS client through the host's Tailscale routing.

### 1. Install NFS Client

```bash
sudo apt install nfs-common
```

### 2. Create Mount Point

```bash
sudo mkdir -p /opt/shared
```

### 3. Test Mount

```bash
sudo mount -t nfs4 100.64.0.1:/opt/shared /opt/shared -o soft,timeo=150
```

Verify:

```bash
ls /opt/shared
touch /opt/shared/.write_test && rm /opt/shared/.write_test && echo "read/write OK"
```

### 4. Persistent Mount (fstab)

Add to `/etc/fstab`:

```
100.64.0.1:/opt/shared  /opt/shared  nfs4  _netdev,x-systemd.automount,x-systemd.idle-timeout=600,soft,timeo=150  0  0
```

Then:

```bash
sudo systemctl daemon-reload
sudo mount /opt/shared
```

Options explained:

| Option | Purpose |
|--------|---------|
| `_netdev` | Wait for network before mounting |
| `x-systemd.automount` | Mount on first access, not at boot |
| `x-systemd.idle-timeout=600` | Unmount after 10 min idle |
| `soft` | Return errors instead of hanging if server unreachable |
| `timeo=150` | 15-second timeout for operations |

## NFS Server Setup (sfspark1)

For reference, the server side configuration:

```bash
sudo apt install nfs-kernel-server

# /etc/exports
/opt/shared  100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)

sudo exportfs -ra
sudo systemctl enable --now nfs-server
```

The export is restricted to the Tailscale CGNAT range (100.64.0.0/10), so only
mesh nodes can access it. WireGuard encryption on the Tailscale tunnel secures
traffic in transit.

## Verification

```bash
# Confirm mesh connectivity
tailscale status              # Run from PowerShell on Windows host

# From WSL2, verify routing to mesh
ping -c 1 100.64.0.1          # Should reach sfspark1

# Confirm NFS mount
mount | grep nfs4
ls /opt/shared
```

## Troubleshooting

### Mount hangs or times out

1. Confirm the Windows host is connected to the mesh:
   ```powershell
   # PowerShell
   tailscale status
   ```

2. Test TCP connectivity from WSL2:
   ```bash
   nc -zv 100.64.0.1 2049
   ```

3. If port 2049 is unreachable, check that the NFS server is running on
   sfspark1:
   ```bash
   ssh sfspark1 'systemctl status nfs-server'
   ```

### Permission denied on mount

Verify the export allows the Tailscale subnet:

```bash
ssh sfspark1 'sudo exportfs -v'
```

The `clientaddr` in the mount output should be a 100.64.x.x address.

### Stale file handle after WSL2 restart

WSL2 restarts lose the mount. If using fstab with `x-systemd.automount`, the
next access will remount automatically. Otherwise:

```bash
sudo umount -l /opt/shared
sudo mount /opt/shared
```

### Mirrored mode not working

Recent Windows 11 updates have broken mirrored networking. If WSL2 falls back
to NAT mode, outbound NFS mounts may still work (traffic routes through NAT to
the host), but verify with:

```bash
# Check if WSL2 has a 100.64.x.x address
ip addr | grep 100.64
```

If not present, you are in NAT mode. The NFS mount should still function since
outbound TCP from WSL2 traverses the host's network stack either way.

## Mesh Topology Reference

```
Node                    Tailscale IP    OS        Role
----                    ------------    --        ----
sfspark1                100.64.0.1      Linux     NFS server, shared storage
office-one (WSL2)       100.64.0.3      Linux     NFS client (via host Tailscale)
office-one (Windows)    100.64.0.4      Windows   Tailscale endpoint
```

WSL2 does not have its own Tailscale identity. It shares the Windows host's
mesh presence and routes through its tunnel.
