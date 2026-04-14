# Changelog

All notable changes to this project will be documented in this file.

## [0.6.0] - 2026-04-14

### Added
- `mesh harden` command group for privacy hardening
  - `mesh harden server` — Deploy hardened Headscale configuration
  - `mesh harden client` — Deploy logtail suppression on current node
  - `mesh harden remote <host>` — Deploy logtail suppression on remote node via SSH
  - `mesh harden status` — Validate privacy hardening state
  - `mesh harden show-templates` — List available hardening templates
- Privacy-hardening templates: Headscale config, ACL policy, logtail suppression, Caddyfile, firewall port matrix, deployment checklist, join scripts
- `core/privacy.py` validation module: DERP map, logtail, DNS acceptance, config checks
- Security section in `mesh status` output (DERP map, logtail, DNS, config status)
- Architecture documentation with Mermaid diagrams and security hardening guide
- Docker Compose integration test environment (`tests/integration/`)
- Template content validation and CLI smoke tests

### Changed
- `mesh client setup` now offers logtail suppression deployment after joining
- `mesh remote provision` deploys logtail suppression on Linux nodes automatically
- Windows provisioning script includes logtail suppression step
- `mesh server setup` suggests privacy hardening after installation
- Consistent `--accept-dns=true` across all join paths (was inconsistent: false in remote, unset in client)

## [0.5.0] - 2026-02-04

### Added
- `mesh smb` command group for Samba/SMB file sharing
  - `mesh smb setup-server` — Idempotent Samba server setup on Linux (install, share config, smbpasswd, UFW, systemd drop-ins)
  - `mesh smb add-user` — Add/update Samba user passwords
  - `mesh smb setup-client` — Generate PowerShell drive-mapping script on Windows via SSH
  - `mesh smb status` — Check Samba services, shares, and port status

### Changed
- Rewrote `docs/setup-windows.md` — rclone SFTP mounting via Tailscale (replaces Syncthing-based approach)
- Rewrote `docs/setup-wsl2.md` — NFSv4 mounting via host Tailscale, WSL2 networking constraints documented

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
