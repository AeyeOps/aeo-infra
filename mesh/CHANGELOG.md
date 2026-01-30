# Changelog

All notable changes to this project will be documented in this file.

## [0.4.0] - 2026-01-30

### Added
- Case study documentation for three-node mesh implementation
  - `docs/case-study/README.md` - Overview and architecture
  - `docs/case-study/JOURNEY.md` - Chronological implementation story
  - `docs/case-study/LESSONS-LEARNED.md` - Key insights and gotchas
  - `docs/case-study/WINDOWS-CREDENTIALS.md` - Deep dive on Windows credential isolation
  - `docs/case-study/WSL-SSH.md` - Deep dive on WSL2 SSH port conflicts
  - `docs/case-study/AGENT-PROTECTION.md` - Protecting infrastructure from AI agents

## [0.3.0] - 2026-01-25

### Added
- Simplified client setup workflow after `mesh init`
- mDNS auto-discovery for Headscale server

### Fixed
- Init → client setup workflow configuration gap

## [0.2.0] - 2026-01-23

### Changed
- Removed hardcoded hostnames from setup-mesh.ps1
- Cleaned up archive/ and internal docs containing PII

## [0.1.0] - 2026-01-20

### Added
- Initial Python CLI for mesh network management
- Server setup commands (Headscale coordination server)
- Client setup commands (Tailscale clients)
- Syncthing peer exchange
- Platform guides for Linux, Windows, and WSL2
