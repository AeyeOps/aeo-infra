# Changelog

All notable changes to this project will be documented in this file.

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
