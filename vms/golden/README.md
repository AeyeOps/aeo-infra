# Windows Golden Image

A golden image is a fully configured Windows installation used as a read-only base for copy-on-write overlay VMs. Overlays are instant to create and disposable -- the golden image is never modified.

## Building

```bash
sudo ./winvm.sh golden build
```

This starts a QEMU VM with the Windows ISO attached on VNC `:9` (port 5909). You install Windows interactively, configure SSH and networking, then shut down. The script converts the raw disk to a compressed qcow2 golden image.

### What gets pre-installed

- Windows 11 ARM64
- OpenSSH Server (auto-start)
- `testuser` account (password: `TestPass123!`, admin)
- Static IP: `192.168.50.200/24`, gateway `192.168.50.1`
- Tailscale client

### Files produced

| File | Purpose |
|------|---------|
| `/storage/golden/windows-test.qcow2` | Compressed disk image (read-only base) |
| `/storage/golden/windows-test.vars` | UEFI variables snapshot |
| `/storage/golden/windows-test.rom` | Padded UEFI firmware (64MB) |

## How overlays work

When you run `winvm.sh start <name>`, it:

1. Creates a qcow2 overlay backed by the golden disk (instant, ~200KB initially)
2. Copies UEFI vars (writable per-VM state)
3. Boots from the overlay -- all writes go to the overlay file
4. The golden image is mounted read-only and never modified

On `winvm.sh destroy <name>`, only the overlay files are deleted. The golden image stays intact for the next VM.

## Rebuilding

```bash
sudo ./winvm.sh golden destroy
sudo ./winvm.sh golden build
```

## Requirements

- Windows 11 ARM64 ISO at `/storage/win11arm64.iso`
- QEMU with KVM support (aarch64)
- UEFI firmware: `/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`
