#!/usr/bin/env bash
# Task #9 deterministic Windows Setup driver.
#
# Workflow:
#   1. Fresh NVRAM wipe (rm + truncate)
#   2. Launch minimal QEMU (ISO on USB, blank SCSI, no QMP, usb-kbd)
#   3. Wait for cdboot timeout → firmware → embedded UEFI Shell (~10s)
#   4. Dismiss startup.nsh 1s prompt (we're already at Shell>), type "exit\n"
#   5. Front-page menu appears: navigate Down Down Enter → Boot Manager
#   6. Press Enter on the pre-highlighted "USB HARDDRIVE" entry → cdboot starts
#   7. IMMEDIATELY spam Space keys — usb-kbd is live from step 5 navigation,
#      so cdboot's "Press any key" prompt is dismissed → Setup loads
set -euo pipefail

WORK=${WORK:-/tmp/winboot}
ISO=${ISO:-/opt/dev/aeo/aeo-infra/vms/.images/win11arm64.iso}
VNC_DISP=${VNC_DISP:-2}
LABEL=${1:-run}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOG=$WORK/qemu-${LABEL}.log
PIDF=$WORK/qemu-${LABEL}.pid

# Step 0: kill any prior qemu
for p in $(pgrep -f qemu-system-aarch64 || true); do sudo -n kill -9 "$p" 2>/dev/null || true; done
sleep 2
rm -f "$PIDF" "$LOG"

# Step 1: fresh NVRAM
sudo -n rm -f "$WORK/build.vars"
sudo -n truncate -s 64M "$WORK/build.vars"
sudo -n chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "$WORK/build.vars"

# Blank first MB of build disk
sudo -n dd if=/dev/zero of="$WORK/build.img" bs=1M count=1 conv=notrunc status=none 2>/dev/null || true

# Step 2: launch qemu in background
sudo -n qemu-system-aarch64 \
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
    -name "winboot-${LABEL}" &
disown
echo "[drive] qemu launched label=${LABEL}"

# Step 3: wait for UEFI Shell (cdboot timeout ~15s, USB enum ~2-5s = ~10s to Shell)
start=$(date +%s)
while [ $(($(date +%s) - start)) -lt 12 ]; do sleep 1; done

# Step 4: confirm we're at the Shell prompt
"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s1-shell.ppm" >/dev/null 2>&1
echo "[drive] t=12s screenshot: ${LABEL}-s1-shell.ppm"

# Step 5: type 'exit' to leave Shell → front-page menu
"$SCRIPT_DIR/vnc_full.py" --port 5902 --type $'exit\n' --post-delay 1.5 >/dev/null 2>&1
"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s2-menu.ppm" >/dev/null 2>&1
echo "[drive] exited Shell → menu screenshot: ${LABEL}-s2-menu.ppm"

# Step 6: Down Down Enter → Boot Manager
"$SCRIPT_DIR/vnc_send_keys.py" --port 5902 --keys "Down Down Enter" --post-delay 1.0 >/dev/null 2>&1
"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s3-bootmgr.ppm" >/dev/null 2>&1
echo "[drive] entered Boot Manager: ${LABEL}-s3-bootmgr.ppm"

# Step 7a: Enter on USB HARDDRIVE (pre-highlighted) → cdboot starts
"$SCRIPT_DIR/vnc_send_keys.py" --port 5902 --keys "Enter" --post-delay 0.3 >/dev/null 2>&1
echo "[drive] selected USB HARDDRIVE, starting key spam"

# Step 7b: persistent RFB connection that spams Space for 22s at 8/s
# This covers cdboot's prompt window (~15s) with margin.
"$SCRIPT_DIR/vnc_spam_keys.py" --port 5902 --key Space --duration 22 --rate 8 --hold-ms 60 >/dev/null 2>&1 || true
echo "[drive] space-key spam complete"

# Wait for bootmgfw + WinPE to load Setup (~5-10s after successful cdboot)
start=$(date +%s)
while [ $(($(date +%s) - start)) -lt 10 ]; do sleep 1; done

"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s4-setup.ppm" >/dev/null 2>&1
convert "$WORK/${LABEL}-s4-setup.ppm" "$WORK/${LABEL}-s4-setup.png" 2>/dev/null || true
echo "[drive] final screenshot: ${LABEL}-s4-setup.png"
echo "[drive] DONE — inspect ${LABEL}-s4-setup.png to confirm Setup is loaded"
