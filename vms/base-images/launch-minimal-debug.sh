#!/usr/bin/env bash
# Minimal QEMU for ARM64 Windows 11 UEFI Shell experiments.
# Per DEBUG_NOTES.md: Windows ISO on USB, blank disk, usb-kbd, NO bootindex,
# NO QMP, NO extra USB devices → cdboot times out in ~10s, firmware falls
# through to embedded UEFI Shell. VNC for both input (full-RFB) and screen.
set -euo pipefail

WORK=/tmp/winboot
ISO=/opt/dev/aeo/aeo-infra/vms/.images/win11arm64.iso
VNC_DISP=2          # port 5902
LOG=$WORK/qemu.log
PIDF=$WORK/qemu.pid

# Kill any prior instance
if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    sudo -n kill "$(cat "$PIDF")" || true
    sleep 1
fi
rm -f "$PIDF" "$LOG"

exec sudo -n qemu-system-aarch64 \
    -nodefaults \
    -cpu host -enable-kvm \
    -machine type=virt,secure=off,gic-version=max,accel=kvm \
    -smp 4,sockets=1,cores=4,threads=1 \
    -m 8G \
    -display "vnc=:${VNC_DISP}" \
    -device ramfb \
    -device qemu-xhci \
    -device usb-kbd \
    -drive "file=${ISO},id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
    -device usb-storage,drive=cdrom0,removable=on \
    -object iothread,id=io0 \
    -device virtio-scsi-pci,id=scsi0,bus=pcie.0,iothread=io0 \
    -drive "file=${WORK}/build.img,id=disk0,format=raw,cache=none,aio=native,if=none" \
    -device scsi-hd,drive=disk0,bus=scsi0.0 \
    -drive "file=${WORK}/build.rom,if=pflash,unit=0,format=raw,readonly=on" \
    -drive "file=${WORK}/build.vars,if=pflash,unit=1,format=raw" \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-pci,rng=rng0 \
    -rtc base=localtime \
    -pidfile "$PIDF" \
    -D "$LOG" \
    -name "winboot-minimal"
