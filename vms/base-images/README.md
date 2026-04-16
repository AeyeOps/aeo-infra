# Windows Base Image

A fully configured Windows 11 ARM64 installation used as a read-only base
for instant copy-on-write overlay VMs.

## Current status

**The unattended build does not yet work end-to-end.** The blocking issue
is getting Windows Setup to boot reliably from the ISO on ARM64 QEMU.
See [BOOT.md](BOOT.md) for the full technical picture before attempting
any fix.

A flaky-but-retryable path exists (see `drive-setup.sh` /
`drive-setup-retry.sh`) that reaches the Setup UI ~50% per attempt. The
root cause of the flakiness has not been investigated at the source level.

## Building

```bash
sudo ./winvm.sh image build
```

Phase 1 boots QEMU with the Windows ISO, VirtIO drivers, and a build
disk seeded with `autounattend.xml`. WinPE extracts install.wim to disk
and reboots. Phase 2 boots from disk (no ISO) through specialize, OOBE,
and FirstLogonCommands, then shuts down. The raw disk is converted to a
compressed qcow2 base image.

### What gets installed

- Windows 11 Pro ARM64
- VirtIO storage (vioscsi) and network (NetKVM) drivers
- OpenSSH Server (auto-start)
- `testuser` account (password: `TestPass123!`, admin)
- Static IP: `192.168.50.200/24`, gateway `192.168.50.1`
- Tailscale client

### Files produced

| File | Purpose |
|------|---------|
| `vms/.images/base-images/windows-test.qcow2` | Compressed disk (read-only base) |
| `vms/.images/base-images/windows-test.vars` | UEFI variables snapshot |
| `vms/.images/base-images/windows-test.rom` | Padded UEFI firmware (64 MB) |

### Answer file

Driven by `autounattend.xml` in this directory. Handles hardware-requirement
bypasses, UEFI/GPT disk partitioning, VirtIO driver injection, OOBE skip,
local account, and FirstLogonCommands. See `../kb/windows-autounattend.md`
for the full reference.

## How overlays work

`winvm.sh start <name>` creates a qcow2 overlay backed by the base disk
(instant, ~200 KB initially), copies UEFI vars, and boots. All writes go
to the overlay. `winvm.sh destroy <name>` deletes only the overlay.

## Requirements

- Windows 11 ARM64 ISO at `vms/.images/win11arm64.iso`
- VirtIO drivers ISO at `vms/.images/virtio-win.iso`
- QEMU with KVM (aarch64), UEFI firmware (`/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`)
- `sgdisk`, `mkfs.fat`, `mtools` for build-disk seeding
- `7z` for ISO extraction (if doing BCD analysis)

## Troubleshooting

- If build stalls, check VNC `:9` or `/tmp/winbuild-latest.ppm`
- If SSH verification fails, boot a VM and check `C:\Windows\Temp\firstlogon.log`
- Build timeout is 3h soft cap (warns but does not kill)
- **NVRAM must be wiped correctly**: `rm -f build.vars && truncate -s 64M build.vars`.
  Plain `truncate` on an already-sized file is a no-op. Stale NVRAM poisons boot.

## Tools in this directory

| File | Purpose |
|------|---------|
| `vnc_full.py` | Full RFB 3.8 client: `--type TEXT` and `--screenshot PATH.ppm` |
| `vnc_send_keys.py` | Named-key sender (Down, Enter, Esc, F-keys) |
| `vnc_spam_keys.py` | Persistent-connection key spammer (rate/duration configurable) |
| `launch-minimal-debug.sh` | Minimal QEMU that drops to UEFI Shell (VNC :2) |
| `drive-setup.sh` | Single-attempt Boot Manager + keyspam sequence (~50% hit rate) |
| `drive-setup-retry.sh` | Retry wrapper for drive-setup.sh (default 5 attempts) |
| `autounattend.xml` | Windows unattended answer file |
