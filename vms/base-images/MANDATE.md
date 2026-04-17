# Windows base image build — mandate

## The goal

Produce a working `vms/.images/base-images/windows-test.qcow2` by running:

```
sudo /opt/dev/aeo/aeo-infra/vms/winvm.sh image build
```

The qcow2 must be a Windows 11 ARM64 install that:

- boots under QEMU
- answers SSH at `192.168.50.200` as `testuser`
- has Tailscale installed

…i.e. it passes the script's built-in SSH verification step.

## What is negotiable

How we get there. The install path, which firmware, whether we use
Windows Setup versus a prebuilt VHDX, the retry strategy — all open.

## What is not negotiable

Functionality cannot be altered, reduced, or sidestepped. No dropping
steps, trimming requirements, weakening verification, or substituting
a narrower artifact because the real one is hard.

If the honest path forward is to solve the underlying problem, solve it.

If the inclination is to find a way out that would not actually achieve
the requested result, stop and say so. A known failure reported clearly
is better than a false success delivered quietly.
