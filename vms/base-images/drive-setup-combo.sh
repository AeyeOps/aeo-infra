#!/usr/bin/env bash
# Task #14 / Approach A: drive-setup with QMP + VNC keyspam combined.
#
# Hypothesis: cdboot's SimpleTextInput poll has a ~50% race against any
# single input source. Doubling up via QMP `input-send-event` (sending 'ret')
# PLUS the existing VNC RFB keyspam (sending Space) may saturate the poll
# and guarantee a hit.
#
# Differences from drive-setup.sh:
#   - Adds -qmp unix:<sock>,server=on,wait=off
#   - During step 7b: forks two parallel keyspammers (VNC Space + QMP ret)
set -euo pipefail

WORK=${WORK:-/tmp/winboot}
ISO=${ISO:-/opt/dev/aeo/aeo-infra/vms/.images/win11arm64.iso}
VNC_DISP=${VNC_DISP:-2}
LABEL=${1:-combo}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOG=$WORK/qemu-${LABEL}.log
PIDF=$WORK/qemu-${LABEL}.pid
QMP_SOCK=$WORK/qmp-${LABEL}.sock

# Step 0: kill any prior qemu
for p in $(pgrep -f qemu-system-aarch64 || true); do sudo -n kill -9 "$p" 2>/dev/null || true; done
sleep 2
rm -f "$PIDF" "$LOG" "$QMP_SOCK"

# Step 1: fresh NVRAM (rm + truncate, NEVER truncate alone)
sudo -n rm -f "$WORK/build.vars"
sudo -n truncate -s 64M "$WORK/build.vars"
sudo -n chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "$WORK/build.vars"

# Blank first MB of build disk
sudo -n dd if=/dev/zero of="$WORK/build.img" bs=1M count=1 conv=notrunc status=none 2>/dev/null || true

# Step 2: launch qemu in background WITH QMP socket
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
    -qmp "unix:${QMP_SOCK},server=on,wait=off" \
    -pidfile "$PIDF" \
    -D "$LOG" \
    -name "winboot-${LABEL}" &
disown
echo "[combo] qemu launched label=${LABEL} qmp=${QMP_SOCK}"

# Make qmp socket readable by current user
sudo -n chmod 666 "$QMP_SOCK" 2>/dev/null || true
# Wait briefly for socket to be created and chmod it
for i in 1 2 3 4 5; do
    if [ -S "$QMP_SOCK" ]; then
        sudo -n chmod 666 "$QMP_SOCK" 2>/dev/null || true
        break
    fi
    sleep 1
done

# Step 3: wait for UEFI Shell (cdboot timeout ~15s; USB enum ~2-5s)
start=$(date +%s)
while [ $(($(date +%s) - start)) -lt 12 ]; do sleep 1; done

# Step 4: confirm Shell prompt
"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s1-shell.ppm" >/dev/null 2>&1
echo "[combo] t=12s screenshot: ${LABEL}-s1-shell.ppm"

# Step 5: type 'exit' to leave Shell -> front-page menu
"$SCRIPT_DIR/vnc_full.py" --port 5902 --type $'exit\n' --post-delay 1.5 >/dev/null 2>&1
"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s2-menu.ppm" >/dev/null 2>&1
echo "[combo] menu screenshot: ${LABEL}-s2-menu.ppm"

# Step 6: Down Down Enter -> Boot Manager
"$SCRIPT_DIR/vnc_send_keys.py" --port 5902 --keys "Down Down Enter" --post-delay 1.0 >/dev/null 2>&1
"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s3-bootmgr.ppm" >/dev/null 2>&1
echo "[combo] bootmgr screenshot: ${LABEL}-s3-bootmgr.ppm"

# Step 7a: Enter on USB HARDDRIVE -> cdboot starts
"$SCRIPT_DIR/vnc_send_keys.py" --port 5902 --keys "Enter" --post-delay 0.3 >/dev/null 2>&1
echo "[combo] selected USB HARDDRIVE, starting DUAL-CHANNEL keyspam"

# Step 7b: TWO parallel spammers, both targeting cdboot's prompt window
"$SCRIPT_DIR/vnc_spam_keys.py" --port 5902 --key Space \
    --duration 22 --rate 8 --hold-ms 60 \
    >/tmp/winboot/${LABEL}-vnc-spam.log 2>&1 &
VNC_PID=$!
"$SCRIPT_DIR/qmp_spam_keys.py" --sock "$QMP_SOCK" --key ret \
    --duration 22 --rate 8 --hold-ms 60 \
    >/tmp/winboot/${LABEL}-qmp-spam.log 2>&1 &
QMP_PID=$!
echo "[combo] forked vnc=${VNC_PID} qmp=${QMP_PID}"

wait $VNC_PID 2>/dev/null || true
wait $QMP_PID 2>/dev/null || true
echo "[combo] keyspam complete"

# Wait for bootmgfw + WinPE -> Setup
start=$(date +%s)
while [ $(($(date +%s) - start)) -lt 10 ]; do sleep 1; done

"$SCRIPT_DIR/vnc_full.py" --port 5902 --screenshot "$WORK/${LABEL}-s4-setup.ppm" >/dev/null 2>&1
convert "$WORK/${LABEL}-s4-setup.ppm" "$WORK/${LABEL}-s4-setup.png" 2>/dev/null || true
echo "[combo] final screenshot: ${LABEL}-s4-setup.png"
