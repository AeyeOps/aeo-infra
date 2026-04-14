# Security Hardening Guide

## Why Harden

A vanilla Headscale + Tailscale deployment is functional out of the box, but it leaves
several privacy-relevant gaps:

- **Public DERP relay dependence** -- Encrypted relay traffic passes through
  Tailscale's public DERP infrastructure. Even though the payload is encrypted,
  connection metadata (which nodes relay through which servers, when, and how
  often) is visible to the relay operator.
- **Client logtail to a public logging service** -- Every Tailscale client
  streams structured telemetry to Tailscale's cloud logging endpoint on startup.
  The server-side `logtail.enabled: false` setting only silences the Headscale
  process itself; it does not affect clients.
- **DNS override defaults** -- The default `override_local_dns: true` rewrites
  the node's DNS configuration, which can break consumer VPN overlays and local
  resolver chains.
- **Weak ACL defaults** -- Without an explicit policy file, all nodes can reach
  all other nodes on every port.

These are not bugs. They are architectural defaults designed for the hosted
Tailscale service that need explicit hardening when running a private mesh.

## The Four Hardening Areas

### 1. DERP Privacy

Enable the embedded DERP relay inside Headscale and remove the public DERP map
so that relay traffic never leaves your own infrastructure.

Key configuration (in `headscale-config-template.yaml`):

```yaml
derp:
  server:
    enabled: true
    region_id: 900
    region_code: "corp"
    region_name: "Corporate Embedded DERP"
    verify_clients: true
    stun_listen_addr: "0.0.0.0:3478"
    automatically_add_embedded_derp_region: true
    ipv4: 203.0.113.10
    ipv6: 2001:db8::10
  urls: []          # No public DERP map
  paths: []
  auto_update_enabled: false
```

- `urls: []` removes the default `https://controlplane.tailscale.com/derpmap/default`
  entry, ensuring clients never learn about public relays.
- `verify_clients: true` requires connecting DERP clients to present valid
  WireGuard credentials, blocking unauthorized relay use.

### 2. Logtail Suppression

Setting `logtail.enabled: false` in the Headscale server config only stops the
server process from sending telemetry. Every Tailscale client must be
independently configured to suppress its own logtail stream.

**Linux and WSL** -- Deploy `/etc/default/tailscaled`:

```
PORT="41641"
TS_NO_LOGS_NO_SUPPORT=true
FLAGS=""
```

**Windows** -- Deploy `%ProgramData%\Tailscale\tailscaled-env.txt`:

```
TS_NO_LOGS_NO_SUPPORT=true
```

The environment variable must be present before `tailscaled` starts. Restarting
the Tailscale service after deploying the file is required.

### 3. DNS Policy

Use `override_local_dns: false` with empty global nameservers. MagicDNS handles
mesh name resolution (names under `mesh.example.net`), while the node's existing
local resolvers handle all public DNS queries.

```yaml
dns:
  magic_dns: true
  base_domain: mesh.example.net
  override_local_dns: false
  nameservers:
    global: []
    split: {}
```

This avoids a common coexistence problem: when `override_local_dns` is true,
Tailscale rewrites `/etc/resolv.conf` (or the Windows DNS client), which can
break consumer VPN overlays, corporate split-tunnel configurations, and local
stub resolvers like `systemd-resolved`.

### 4. ACL and SSH Policy

Use tag-based least privilege instead of broad allow rules. The
`policy.hujson` template provides a starting point:

- **Groups** define human identities (`group:netops`, `group:platform`).
- **Tags** classify node roles (`tag:server`, `tag:workstation`, `tag:infra`).
- **ACLs** grant group-to-tag access, not group-to-group or `*:*`.
- **SSH rules** limit which groups can SSH into which tags and as which users.

Review and tighten the default policy before rolling out to production nodes.

## Using `mesh harden`

| Command | What it does |
|---|---|
| `mesh harden server` | Deploy hardened Headscale config, DERP, logtail, DNS, and ACL policy on the coordination server |
| `mesh harden client` | Deploy logtail suppression on the current node |
| `mesh harden remote <host>` | Deploy logtail suppression on a remote node via SSH |
| `mesh harden status` | Validate hardening state across DERP, logtail, DNS, and policy |
| `mesh harden show-templates` | List all available privacy-hardening templates |

All subcommands are idempotent. Running them again after a drift event
re-applies the intended state.

## What `mesh status` Reports

The `mesh status` command includes diagnostics relevant to hardening:

- **Tailscale connectivity** -- Whether the client is connected and its mesh IP.
- **Peer reachability** -- Online/offline state for each peer (with `--verbose`).
- **Syncthing state** -- Whether the file-sync layer is operational.
- **Headscale server** -- The configured control-plane URL.

When combined with `mesh harden status`, operators get a full picture of both
connectivity health and privacy posture.

## Template Reference

| Template | Purpose | Deployment target |
|---|---|---|
| `headscale-config-template.yaml` | Hardened Headscale server configuration with embedded DERP, logtail suppression, and conservative DNS | `/etc/headscale/config.yaml` on the server |
| `policy.hujson` | Tag-based ACL and SSH policy | `/etc/headscale/policy.hujson` on the server |
| `Caddyfile.headscale` | Minimal reverse proxy config for TLS termination | `/etc/caddy/Caddyfile` on the server |
| `tailscaled.default.private` | Logtail suppression environment for Linux and WSL | `/etc/default/tailscaled` on each Linux/WSL node |
| `windows-tailscaled-env.txt` | Logtail suppression environment for Windows | `%ProgramData%\Tailscale\tailscaled-env.txt` on each Windows node |
| `firewall-port-matrix.csv` | Reference table of every port the mesh requires | Planning reference (not deployed) |
| `deployment-checklist.md` | Step-by-step checklist for a greenfield deployment | Planning reference (not deployed) |
| `join-linux-node.sh` | Shell script to join a Linux node to the mesh | Run once per Linux/WSL node |
| `join-windows-node.ps1` | PowerShell script to join a Windows node to the mesh | Run once per Windows node |

## VPN Coexistence

Running a consumer VPN overlay alongside Tailscale on Windows is a common
deployment scenario. The key principles:

1. **Keep the Headscale control plane private first.** If the mesh is already
   hardened (private DERP, suppressed logtail, conservative DNS), the
   consumer VPN overlay has less surface to interfere with.

2. **Avoid depending on broad app-level split tunneling.** App split tunneling
   in consumer VPN overlays is unreliable for background services like
   `tailscaled` because the overlay may not correctly classify system services.

3. **Validate after any VPN state change.** After connecting or disconnecting
   the consumer VPN overlay, verify:
   - Public egress IP matches expectations (for the VPN's intended purpose).
   - Tailscale node health is green (`tailscale status`).
   - MagicDNS names resolve correctly.
   - Tailscale SSH to mesh peers still works.

4. **Common issues:**
   - **Client-side DNS acceptance drift** -- The consumer VPN overlay rewrites
     DNS settings, causing MagicDNS queries to fail. Setting
     `override_local_dns: false` reduces but does not eliminate this.
   - **Control-plane traffic rerouted** -- The consumer VPN overlay captures
     traffic to the Headscale FQDN, causing client registration to fail or
     time out.
   - **DERP relay blocked** -- The consumer VPN overlay blocks or reroutes
     UDP 3478 (STUN) or TCP 443 to the DERP endpoint.

5. **Do not name or depend on product-specific workarounds.** Consumer VPN
   overlay behavior changes across versions. Test the actual combination in
   your environment.

## Recommended Follow-Up Controls

These are not implemented by `mesh harden` today but are recommended for
production deployments:

- **Add a second private DERP region** in a different fault domain (different
  cloud region or physical site). A single DERP region means relay-dependent
  peers lose connectivity if that region goes down.
- **Introduce private recursive DNS resolvers** so that public DNS queries
  also stay within your infrastructure instead of reaching upstream public
  resolvers.
- **Tighten ACL and SSH policy** beyond the starter template. Restrict port
  ranges, add time-based rules if supported, and remove broad SSH access.
- **Add periodic drift detection** for the DERP map, logtail suppression,
  and DNS acceptance settings. Client-side state can drift after OS updates,
  Tailscale upgrades, or consumer VPN overlay changes.
- **Centralize your own service logging** to replace the suppressed logtail
  stream. Without telemetry flowing to Tailscale, you are responsible for
  your own observability.

## Residual Risks

Even after applying all hardening measures, the following residual risks remain:

- **Single DERP region** -- If only one embedded DERP region is deployed,
  relay-dependent peers have no fallback. This is a resilience risk, not a
  privacy risk, but it affects availability.
- **Public DNS recursion still local** -- MagicDNS handles mesh names, but
  public DNS queries still go to whatever upstream resolvers the node is
  configured to use. Until private recursive resolvers are deployed, public
  DNS query metadata is visible to those upstream providers.
- **Client-state drift** -- Logtail suppression and DNS acceptance are
  client-side settings that can be reset by OS updates, Tailscale package
  upgrades, or consumer VPN overlay interference. Server-side configuration
  alone cannot enforce these. Periodic validation (via `mesh harden status`)
  is required to detect drift.
