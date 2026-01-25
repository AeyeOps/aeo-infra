#!/bin/bash
# Start Windows VM with shared bridge networking
# Run with sudo: sudo ./start-windows-vm.sh
#
# This replaces the original Windows VM startup to use the shared br-vm bridge.
# Based on the original QEMU command but with unified networking.

set -e

STORAGE_DIR="/storage"
VM_NAME="windows"

# VM Configuration (matching original)
RAM="8G"
CPUS="4"
MAC_ADDR="02:58:EC:4C:35:33"

# Files
ISO_FILE="${STORAGE_DIR}/win11arm64.iso"
DISK_FILE="${STORAGE_DIR}/data.img"
VARS_FILE="${STORAGE_DIR}/windows.vars"
UEFI_ROM="${STORAGE_DIR}/windows.rom"

# Network - uses shared bridge TAP
TAP_NAME="qemu"

# Display
VNC_DISPLAY=":0"
VNC_WS_PORT="5700"
MONITOR_PORT="7100"

# Logs
LOG_FILE="/run/shm/qemu.log"
PID_FILE="/run/shm/qemu.pid"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

# Check if already running
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Windows VM already running (PID: $(cat $PID_FILE))"
    exit 1
fi

# Ensure network is set up (creates bridge + TAPs if needed)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/setup-vm-network.sh"

# Verify required files
for f in "$UEFI_ROM" "$DISK_FILE" "$VARS_FILE"; do
    if [[ ! -f "$f" ]]; then
        echo "Missing: $f"
        exit 1
    fi
done

echo "Starting Windows VM..."

qemu-system-aarch64 \
    -nodefaults \
    -cpu host \
    -smp "${CPUS},sockets=1,dies=1,cores=${CPUS},threads=1" \
    -m "$RAM" \
    -machine "type=virt,secure=off,gic-version=max,dump-guest-core=off,accel=kvm" \
    -enable-kvm \
    -smbios type=1,serial=76XX5G4 \
    -display "vnc=${VNC_DISPLAY},websocket=${VNC_WS_PORT}" \
    -device ramfb \
    -monitor "telnet:localhost:${MONITOR_PORT},server,nowait,nodelay" \
    -daemonize \
    -D "$LOG_FILE" \
    -pidfile "$PID_FILE" \
    -name "${VM_NAME},process=${VM_NAME},debug-threads=on" \
    -serial pty \
    -device "qemu-xhci,id=xhci,p2=7,p3=7" \
    -device usb-kbd \
    -device usb-tablet \
    -netdev "tap,id=hostnet0,ifname=${TAP_NAME},script=no,downscript=no" \
    -device "virtio-net-pci,id=net0,netdev=hostnet0,romfile=,mac=${MAC_ADDR}" \
    -drive "file=${ISO_FILE},id=cdrom9,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
    -device "usb-storage,drive=cdrom9,bootindex=9,removable=on" \
    -drive "file=${DISK_FILE},id=data3,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none" \
    -device "virtio-scsi-pci,id=data3b,bus=pcie.0,addr=0xa,iothread=io2" \
    -device "scsi-hd,drive=data3,bus=data3b.0,channel=0,scsi-id=0,lun=0,rotation_rate=1,bootindex=3" \
    -object "iothread,id=io2" \
    -rtc base=localtime \
    -drive "file=${UEFI_ROM},if=pflash,unit=0,format=raw,readonly=on" \
    -drive "file=${VARS_FILE},if=pflash,unit=1,format=raw" \
    -object "rng-random,id=objrng0,filename=/dev/urandom" \
    -device "virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0"

sleep 1

if [[ -f "$PID_FILE" ]]; then
    echo ""
    echo "Windows VM started (PID: $(cat $PID_FILE))"
    echo ""
    echo "Access:"
    echo "  VNC:       localhost${VNC_DISPLAY} (port 5900)"
    echo "  WebSocket: ws://localhost:${VNC_WS_PORT}"
    echo "  Monitor:   telnet localhost ${MONITOR_PORT}"
    echo ""
    echo "Network: Configure IP 192.168.50.11, gateway 192.168.50.1"
fi
