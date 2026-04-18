# aeo-infra

**v0.2.0** · Infrastructure tooling for reusable VMs and multi-machine development.

## What This Repo Is

This repo gives you two practical building blocks:

| Directory | What it does | Who it is for |
|-----------|--------------|----------------|
| [`vms/`](vms/) | Builds and runs QEMU/KVM virtual machines | Anyone who wants disposable local VMs, especially a reusable Windows 11 ARM64 base image |
| [`mesh/`](mesh/) | Sets up a self-hosted mesh network between machines | Anyone who wants machines to find each other and sync over a private network |

The most important user-facing artifact in this repo is the Windows base image built by `vms/winvm.sh`. That image is not limited to Mesh. It is a general-purpose Windows 11 ARM64 QEMU image that already has SSH and Tailscale installed, so it can be used anywhere that workflow is useful.

> **Note:** The vLLM deployment project has moved to its own repo: [steveant/aeo-vllm-gb10](https://github.com/steveant/aeo-vllm-gb10)

## Why It Is Valuable

- You can build Windows once and reuse it instead of reinstalling Windows for every VM.
- You get a bootable `windows-test.qcow2` base image that the scripts verify before declaring ready.
- You can create disposable Windows VMs quickly from that base image using copy-on-write overlays.
- You can start from a guest that already has SSH enabled and Tailscale installed.

## Windows Base Image Quick Start

If your goal is a reusable Windows 11 ARM64 image for QEMU, this is the path:

```bash
cd vms
sudo ./winvm.sh image build
```

What that build does:

- creates `vms/.images/base-images/windows-test.qcow2`
- verifies that the guest boots and answers SSH at `192.168.50.200` as `testuser`
- leaves Tailscale installed in the image

Once the base image exists, use it to start disposable Windows VMs:

```bash
cd vms
sudo ./winvm.sh start demo
./winvm.sh ssh demo
./winvm.sh exec demo "hostname"
sudo ./winvm.sh destroy demo
```

What those commands mean:

- `start demo` creates a temporary overlay on top of the shared base image and boots it
- `ssh demo` connects to the running guest
- `exec demo ...` runs a command inside the guest
- `destroy demo` removes the overlay and leaves the shared base image untouched

See [`vms/README.md`](vms/README.md) for the VM command set and [`vms/base-images/README.md`](vms/base-images/README.md) for the Windows image details.

## Mesh Quick Start

If your goal is machine-to-machine networking and sync, use `mesh/`:

```bash
cd mesh
uv sync
uv run mesh --help

# Server setup
uv run mesh server setup

# Client setup
uv run mesh client setup --server http://<server>:8080 --key <KEY>

# Status
uv run mesh status
```

See [`mesh/README.md`](mesh/README.md) for the full mesh workflow.

## Configuration

Copy `.env.example` to `.env` and customize it for your environment:

```bash
cp .env.example .env
# Edit .env with your hostnames, IPs, and username
```

## Requirements

### For `mesh/`

- Python 3.13+
- `uv`

### For `vms/`

- QEMU/KVM
- UEFI firmware
- Host support suitable for the VM workflow you want to run

## License

MIT
