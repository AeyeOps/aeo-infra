# Mesh Network Tools

Python CLI for managing a self-hosted mesh network using Headscale (Tailscale control server) and Syncthing (distributed file sync).

## Platform Guides

- [Linux Setup](docs/setup-linux.md) - Ubuntu, Debian, Fedora (x64/ARM64)
- [Windows Setup](docs/setup-windows.md) - Windows 10/11 (x64/ARM64)
- [WSL2 Setup](docs/setup-wsl2.md) - Windows Subsystem for Linux 2

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
