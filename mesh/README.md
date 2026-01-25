# Mesh Network Tools

Python CLI for managing a self-hosted mesh network using Headscale (Tailscale control server) and Syncthing (distributed file sync).

## Installation

```bash
# Development
cd /opt/shared/share-tools
uv sync
uv run mesh --help

# Build standalone binary
make build
mesh --version
```

## Usage

```bash
# Server management (sfspark1 only)
mesh server setup              # Install Headscale coordination server
mesh server keygen             # Generate pre-auth key for clients
mesh server status             # Show server status

# Client setup (all machines)
mesh client setup --server http://sfspark1.local:8080 --key <KEY>
mesh client join --key <KEY>   # Re-join with saved server

# Status and diagnostics
mesh status                    # Quick health check
mesh status --verbose          # Detailed diagnostics

# Syncthing peer exchange
mesh peer                      # Interactive device pairing
```

## Architecture

```
sfspark1 (GB10) - Headscale Coordination Server
├── headscale serve (port 8080)
└── Syncthing (port 8384/22000)

Tailscale Mesh VPN
    sfspark1 <--> office-one (Windows + WSL2)
    All nodes use --login-server http://sfspark1.local:8080

Syncthing Cluster (peer-to-peer)
    sfspark1:/opt/shared <-> WSL2:/opt/shared <-> Windows:C:\shared
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
share-tools/
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

Internal tooling for multi-machine development environment.
