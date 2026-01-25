# Changelog

All notable changes to this project will be documented in this file.

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
