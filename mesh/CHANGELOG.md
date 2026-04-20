# Changelog

All notable changes to this project will be documented in this file.

## [0.6.1] - 2026-04-20

### Added
- Embedded DERP in the integration test harness — standalone `derper` container (built in-tree from Tailscale source) on the `meshtest` bridge at `192.168.50.13`, serving DERP-over-TLS on `:443` and STUN on `:3478/udp`.
- Per-run test CA + leaf cert for `derp.meshtest.local`, distributed to Linux clients via an entrypoint wrapper and to Windows VMs via `scp` + `certutil` + hosts-file entry.
- Two previously-skipped DERPMap tests now run and pass (`TestDERPMapValidation::test_no_public_derp_regions`, `test_private_derp_present`). Integration suite now reports `28 passed, 0 skipped`.
- Repo-wide PII scrub test (`TestRepoPIIScrub` in `mesh/tests/test_templates.py`) — regex-with-word-boundary scan of `mesh/` docs, PowerShell scripts, README, and `vms/` scripts. Prevents real usernames/hostnames/IPs from leaking into tracked files.
- Shared canonical PII marker list at `mesh/tests/_pii.py` — single source of truth replacing three duplicated FORBIDDEN lists across `test_templates.py` and `test_mesh_integration.py`.

### Changed
- Windows `tailscale up --timeout` lowered from 60s back to 30s — with DERP reachable, the probe no longer absorbs the old 20–30 s budget, so 30 s is a tighter regression tripwire.
- `conftest.py` `client_a_status` fixture enriches `tailscale status --json` with `DERPMap` sourced from `tailscale debug derp-map` (the `--json` output does not include it).
- Pinned upper bounds on all runtime and dev dependencies in `mesh/pyproject.toml` (e.g., `pydantic>=2.0,<3.0`, `pytest>=8.0,<10.0`). `uv.lock` unchanged at resolution time.

### Security
- Scrubbed real usernames, hostnames, and Tailscale IPs from tracked docs (`mesh/docs/setup-*.md`, `mesh/docs/case-study/*.md`), `mesh/README.md`, `mesh/setup-mesh.ps1`, `mesh/tests/test_host_registry.py`, and `vms/` scripts — replaced with generic placeholders. Canonical forbidden-marker list lives in `mesh/tests/_pii.py`.
- Windows user path in `setup-mesh.ps1` replaced with `$env:LOCALAPPDATA` (redundant hardcoded fallback removed).
- `VM_USER` in `vms/setup-ubuntu-vm.sh` now defaults to `${SUDO_USER:-ubuntu}` rather than a hardcoded value.
- `chown` in `vms/base-images/drive-setup*.sh` parameterized to `${SUDO_USER:-root}`.
- Ubuntu ISO downloads in `vms/setup-ubuntu-vm.sh` and `vms/lib/storage.sh` now verify SHA256 against the CDN-published `SHA256SUMS` file before the ISO is used. Fail-fast on mismatch, missing entry, or missing `curl`.

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
