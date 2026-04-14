# Windows Base Image

A base image is a fully configured Windows installation used as a read-only base for copy-on-write overlay VMs. Overlays are instant to create and disposable -- the base image is never modified.

## Building

```bash
sudo ./winvm.sh image build
```

This runs a fully unattended Windows 11 ARM64 install via `autounattend.xml`. The script:

1. Creates a small ISO from `base-images/autounattend.xml`
2. Boots QEMU with the Windows ISO, VirtIO drivers ISO, and autounattend ISO
3. Windows installs, configures the system, and shuts down automatically
4. The raw disk is converted to a compressed qcow2 base image

No VNC interaction required. Monitor progress via VNC `:9` (port 5909) if desired.

### What gets pre-installed

- Windows 11 Pro ARM64 (25H2)
- VirtIO storage (vioscsi) and network (NetKVM) drivers
- OpenSSH Server (auto-start)
- `testuser` account (password: `TestPass123!`, admin)
- Static IP: `192.168.50.200/24`, gateway `192.168.50.1`
- Tailscale client

### Files produced

| File | Purpose |
|------|---------|
| `/storage/base-images/windows-test.qcow2` | Compressed disk image (read-only base) |
| `/storage/base-images/windows-test.vars` | UEFI variables snapshot |
| `/storage/base-images/windows-test.rom` | Padded UEFI firmware (64MB) |

### Answer file

The unattended install is driven by `autounattend.xml` in this directory. It handles:

- Windows 11 hardware requirement bypasses (TPM, SecureBoot, etc.)
- UEFI/GPT disk partitioning (EFI + MSR + Windows)
- VirtIO driver injection for ARM64 (vioscsi + NetKVM)
- OOBE skip, local account creation, auto-logon
- FirstLogonCommands: OpenSSH, static IP, Tailscale install, auto-shutdown

See `../kb/windows-autounattend.md` for the full autounattend.xml reference.

## How overlays work

When you run `winvm.sh start <name>`, it:

1. Creates a qcow2 overlay backed by the base disk (instant, ~200KB initially)
2. Copies UEFI vars (writable per-VM state)
3. Boots from the overlay -- all writes go to the overlay file
4. The base image is mounted read-only and never modified

On `winvm.sh destroy <name>`, only the overlay files are deleted. The base image stays intact for the next VM.

## Rebuilding

```bash
sudo ./winvm.sh image destroy
sudo ./winvm.sh image build
```

## Requirements

- Windows 11 ARM64 ISO at `/storage/win11arm64.iso`
- VirtIO drivers ISO at `/storage/virtio-win.iso`
- QEMU with KVM support (aarch64)
- UEFI firmware: `/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`
- `genisoimage` for building the autounattend ISO
