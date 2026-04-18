# Windows Base Image

A reusable Windows 11 ARM64 base image for QEMU/KVM.

Build it once, then use `winvm.sh` to start disposable overlay VMs quickly
without reinstalling Windows every time.

## What This Produces

The build creates a shared base image at:

- `vms/.images/base-images/windows-test.qcow2`

It also writes:

- `vms/.images/base-images/windows-test.vars`
- `vms/.images/base-images/windows-test.rom`

The build is only considered complete when `winvm.sh` finishes its built-in
verification step and confirms that the guest boots and answers SSH.

## What Gets Installed

- Windows 11 Pro ARM64
- VirtIO storage and network drivers
- OpenSSH Server
- `testuser` account
- Static IP `192.168.50.200/24` with gateway `192.168.50.1`
- Tailscale

## Build It

From `vms/`:

```bash
sudo ./winvm.sh image build
```

What that command does at a high level:

- creates the Windows install disk and UEFI state
- runs the unattended Windows install
- converts the finished disk to a compressed qcow2 base image
- boots the image again and verifies SSH access before declaring success

## Use It

Once the base image exists:

```bash
sudo ./winvm.sh start demo
./winvm.sh ssh demo
./winvm.sh exec demo "hostname"
sudo ./winvm.sh destroy demo
```

What this means:

- `start demo` creates a disposable qcow2 overlay backed by the base image
- `ssh demo` connects to the guest
- `destroy demo` removes only the overlay, not the shared base image

## Mesh Versus General Use

This image is not limited to Mesh workflows.

Mesh and Tailscale are useful defaults in this repo, but the resulting
`windows-test.qcow2` is a general-purpose Windows 11 ARM64 QEMU base image
that can be used anywhere the rest of your QEMU workflow expects a bootable
Windows guest.

## Answer File

The unattended install is driven by `autounattend.xml` in this directory.
That file handles the Windows install flow, local account setup, and the
first-boot provisioning steps. See [`../kb/windows-autounattend.md`](../kb/windows-autounattend.md)
for more detail.

## Requirements

- Windows 11 ARM64 ISO at `vms/.images/win11arm64.iso`
- VirtIO drivers ISO at `vms/.images/virtio-win.iso`
- QEMU with KVM and ARM64 UEFI firmware
- Helper tools used by the build scripts, such as partitioning and FAT-image tooling

## Troubleshooting

- If the build stalls, check the active VNC console and the latest screenshot artifacts under `vms/.images/`
- If SSH verification fails, inspect the guest after boot and review `C:\Windows\Temp\firstlogon.log`
- `winvm.sh image build` is the source of truth for readiness; the image is not considered done until its verification step passes

## Tools In This Directory

| File | Purpose |
|------|---------|
| `vnc_full.py` | Full RFB 3.8 client for screenshots and typing |
| `vnc_send_keys.py` | Named-key sender and text input helper |
| `vnc_spam_keys.py` | Persistent-connection key spammer |
| `vnc_click.py` | Fixed-coordinate VNC click helper |
| `launch-minimal-debug.sh` | Minimal QEMU launch for firmware-level debugging |
| `drive-setup.sh` | Low-level Windows boot/setup debug helper |
| `drive-setup-retry.sh` | Retry wrapper for setup debugging |
| `autounattend.xml` | Windows unattended answer file template |
