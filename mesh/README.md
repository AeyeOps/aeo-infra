# Mesh Network Tools

Python CLI for managing a self-hosted mesh network using Headscale (Tailscale control server) and Syncthing (distributed file sync).

## Platform Guides

- [Linux Setup](docs/setup-linux.md) - Ubuntu, Debian, Fedora (x64/ARM64)
- [Windows Setup](docs/setup-windows.md) - Windows 10/11 (x64/ARM64)
- [WSL2 Setup](docs/setup-wsl2.md) - Windows Subsystem for Linux 2

## Case Study

- [Three-Node Mesh Implementation](docs/case-study/README.md) - Real-world implementation with lessons learned on SSH port conflicts, Windows credential isolation, and AI agent protection

## Installation

```bash
# Development
uv sync
uv run mesh --help

# Build standalone binary
make build
mesh --version
```

## Configuration

The CLI reads configuration from environment variables. See `../.env.example` for available options:

- `MESH_DEFAULT_USER` - Default SSH username for host connections
- `MESH_SHARED_FOLDER_LINUX` - Linux shared folder path (default: `/opt/shared`)
- `MESH_SHARED_FOLDER_WINDOWS` - Windows shared folder path (default: `C:\shared`)

## Usage

```bash
# Interactive setup wizard
mesh init                      # Guided configuration
mesh init --dry-run            # Preview without writing

# Server management (coordination server only)
mesh server setup              # Install Headscale coordination server
mesh server setup --advertise  # Also enable mDNS auto-discovery
mesh server keygen             # Generate pre-auth key for clients
mesh server status             # Show server status

# Client setup (all machines)
mesh client setup --server http://<server>:8080 --key <KEY>
mesh client setup --discover --key <KEY>   # Auto-discover server via mDNS
mesh client join --key <KEY>   # Re-join with saved server

# Status and diagnostics
mesh status                    # Quick health check
mesh status --verbose          # Detailed diagnostics

# Syncthing peer exchange
mesh peer                      # Interactive device pairing

# SMB/Samba file sharing
mesh smb setup-server --share shared --user myuser   # Configure Samba on Linux
mesh smb add-user myuser                             # Add/update SMB user password
mesh smb setup-client --host windows --server myserver --user myuser  # Generate Windows drive-mapping script
mesh smb status                                      # Check Samba services and shares
```

## Security Hardening

The mesh CLI includes privacy hardening features based on a comprehensive architecture investigation. A vanilla Headscale + Tailscale deployment leaves gaps that need explicit hardening.

### Quick Start

```bash
# Check current hardening state
uv run mesh harden status

# Deploy logtail suppression on current node
uv run mesh harden client

# Deploy hardened Headscale config (server only)
uv run mesh harden server

# Deploy logtail suppression on a remote node
uv run mesh harden remote user@hostname

# List available templates
uv run mesh harden show-templates
```

### What Gets Hardened

| Area | What | Why |
|------|------|-----|
| DERP Privacy | Embedded private DERP, public map removed | Prevents relay metadata through public infrastructure |
| Logtail | `TS_NO_LOGS_NO_SUPPORT=true` on every node | Stops startup log egress to public logging service |
| DNS Policy | `override_local_dns: false`, empty global nameservers | Preserves local DNS, avoids VPN coexistence breakage |
| ACL/SSH | Tag-based least privilege policy | Restricts mesh reachability and SSH access |

The `mesh status` command includes a Security section that reports on these areas.

See `docs/security-hardening.md` for the full guide and `docs/architecture/` for reference diagrams.

### Integration Tests

There are two suites:

```bash
# Fast local tests (no Docker, no VMs)
make test

# Full heterogeneous mesh — 2 Linux containers + 2 Windows VMs + real DERP
make integration-test
```

The full suite spins up a sealed mesh on the `br-vm` bridge and runs pytest against it. End-to-end it takes ~5–10 min and should finish with `28 passed, 0 skipped`.

**What it covers**

- Headscale control plane + 2 Linux Tailscale clients (Docker)
- 2 Windows Tailscale clients (QEMU VMs from the shared base image)
- Reachable, TLS-backed private DERP (in-tree-built `derper` container with a per-run self-signed CA distributed to every client)
- Cross-platform peer discovery, ping, and DERP-map validation

**Prerequisites**

- Docker with compose
- QEMU/KVM and the Windows base image built via `sudo vms/winvm.sh image build` (see [`../vms/README.md`](../vms/README.md))
- `sudo` without password prompt for `vms/winvm.sh` (the test orchestrator calls it to start/stop Windows VMs)

That's all. `make integration-test` generates its own certs, starts everything, runs pytest, and tears the whole mesh down on exit.

**If something fails**, the orchestrator exits non-zero and the most useful output is at the end of its log. Run directly for live output:

```bash
./tests/integration/run-tests.sh
```

## Architecture

```
Server - Headscale Coordination Server
├── headscale serve (port 8080)
└── Syncthing (port 8384/22000)

Tailscale Mesh VPN
    Server <--> Client (Windows + WSL2)
    All nodes use --login-server http://<server>:8080

Syncthing Cluster (peer-to-peer)
    Server:/opt/shared <-> WSL2:/opt/shared <-> Windows:C:\shared
    Ports: 8384-8386 (GUI), 22000-22002 (sync)
```

## Development

```bash
# Code quality
make validate    # ruff format + check + ty typecheck

# Build
make build       # PyInstaller binary -> /usr/local/bin/mesh
make clean       # Remove build artifacts
make distclean   # Also remove mesh.spec
```

## Project Structure

```
mesh/
├── pyproject.toml          # Project config, version source
├── Makefile                # validate, build, clean
├── src/mesh/               # Python package
│   ├── cli.py              # Main typer app
│   ├── commands/           # CLI subcommands
│   ├── core/               # Business logic
│   └── utils/              # Helpers
├── setup-mesh.ps1          # Windows elevated operations
└── archive/                # Archived scripts
    ├── shell/              # Replaced bash scripts
    ├── sshfs/              # Old SSHFS scripts
    └── specs/              # Old specifications
```

## Requirements

- Python 3.13+
- uv (package manager)
- ty (type checker, via uvx)

## License

MIT
