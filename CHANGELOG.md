# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2025-01-25

### Added
- `mesh init` - Interactive setup wizard for guided configuration
  - Detects platform (Linux x64/ARM64, Windows, WSL2)
  - Role selection (server/client)
  - Generates `.env` configuration with backup
  - `--dry-run` flag for preview without writing
- mDNS auto-discovery for mesh servers
  - Server: `mesh server setup --advertise` enables discovery
  - Client: `mesh client setup --discover --key <KEY>` finds server automatically
- Platform-specific documentation
  - `docs/setup-linux.md` - Native Linux guide
  - `docs/setup-windows.md` - Windows guide (with manual install notes)
  - `docs/setup-wsl2.md` - WSL2 guide

### Changed
- `mesh client setup` now requires `--server URL` or `--discover` flag (no default)
- Added `zeroconf>=0.131` dependency for mDNS support

### Removed
- Hardcoded `DEFAULT_SERVER` constant (was PII)

## [0.2.0] - 2025-01-25

### Changed
- **BREAKING**: Renamed `Role.SFSPARK1` to `Role.SERVER` for generic naming
- Role detection now fully configurable via environment variables
- Removed all hardcoded hostname detection from source code

### Added
- `MESH_SERVER_HOSTNAMES` - Configure which hostnames are the coordination server
- `MESH_WSL2_HOSTNAMES` - Configure WSL2 client hostnames
- `MESH_WINDOWS_HOSTNAMES` - Configure Windows client hostnames
- `is_server()` helper function in environment module
- Helpful error messages when role detection fails

### Fixed
- Server commands now work on any machine configured as server (not just "sfspark1")

## [0.1.1] - 2025-01-25

### Changed
- Externalized configuration via `.env` file
- Generalized documentation (removed hardcoded hostnames/IPs)
- Default SSH user now reads from `MESH_DEFAULT_USER` env var (falls back to `$USER`)
- Shared folder paths configurable via `MESH_SHARED_FOLDER_LINUX` and `MESH_SHARED_FOLDER_WINDOWS`

### Added
- `.env.example` template with all configurable values
- Configuration section in README and CLAUDE.md

## [0.1.0] - 2025-01-25

### Added
- Initial release consolidating infrastructure tools
- `mesh/`: Python CLI for Headscale + Syncthing mesh networking (from share-tools)
  - Server setup and key generation
  - Client provisioning (WSL, Windows, Ubuntu)
  - Status diagnostics
  - Syncthing peer exchange
- `vms/`: Bash scripts for QEMU/KVM VM management (from ubuntu-vm)
  - Ubuntu and Windows VM lifecycle (start/stop/reinstall)
  - Shared bridge networking with NAT
  - Cloud-init templates
  - VNC and QEMU monitor access

### Technical
- Fresh git history (neither source had version control)
- MIT license
- Combined documentation with component-specific READMEs preserved
