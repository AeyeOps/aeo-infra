#!/bin/bash
# Start Ubuntu 24.04 Server VM
# Run with sudo: sudo ./start-ubuntu-vm.sh [install]
# Pass 'install' argument to boot from ISO for installation

set -e

STORAGE_DIR="/storage"
VM_NAME="ubuntu"

# VM Configuration
RAM="8G"
CPUS="4"
MAC_ADDR="02:58:EC:4C:35:34"

# Files
ISO_FILE="${STORAGE_DIR}/ubuntu-24.04.3-server-arm64.iso"
DISK_FILE="${STORAGE_DIR}/${VM_NAME}.img"
VARS_FILE="${STORAGE_DIR}/${VM_NAME}.vars"
CLOUD_INIT_ISO="${STORAGE_DIR}/ubuntu-cloud-init.iso"

# UEFI firmware - check saved path from setup, then fallbacks
if [[ -f "${STORAGE_DIR}/.ubuntu-uefi-rom-path" ]]; then
    UEFI_ROM="$(cat "${STORAGE_DIR}/.ubuntu-uefi-rom-path")"
elif [[ -f "${STORAGE_DIR}/windows.rom" ]]; then
    UEFI_ROM="${STORAGE_DIR}/windows.rom"
elif [[ -f "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" ]]; then
    UEFI_ROM="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
else
    echo "Error: No UEFI firmware found. Run setup-ubuntu-vm.sh first."
    exit 1
fi

# Network (matches setup-ubuntu-vm.sh)
TAP_NAME="tap-ubuntu"

# Display (different from Windows VM which uses :0)
VNC_DISPLAY=":1"
VNC_WS_PORT="5701"
MONITOR_PORT="7101"

# Logs
LOG_FILE="/run/shm/qemu-ubuntu.log"
PID_FILE="/run/shm/qemu-ubuntu.pid"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

# Check if already running
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "Ubuntu VM appears to be running (PID: $(cat $PID_FILE))"
    echo "Use: sudo ./stop-ubuntu-vm.sh to stop it first"
    exit 1
fi

# Verify required files exist
for f in "$UEFI_ROM" "$DISK_FILE" "$VARS_FILE"; do
    if [[ ! -f "$f" ]]; then
        echo "Missing required file: $f"
        echo "Run setup-ubuntu-vm.sh first"
        exit 1
    fi
done

# Verify TAP interface exists
if ! ip link show "$TAP_NAME" &>/dev/null; then
    echo "TAP interface $TAP_NAME not found"
    echo "Run setup-ubuntu-vm.sh first"
    exit 1
fi

# Build QEMU command
QEMU_CMD=(
    qemu-system-aarch64
    -nodefaults
    -cpu host
    -smp "${CPUS},sockets=1,dies=1,cores=${CPUS},threads=1"
    -m "$RAM"
    -machine "type=virt,secure=off,gic-version=max,dump-guest-core=off,accel=kvm"
    -enable-kvm

    # Display: VNC with websocket (different port from Windows)
    -display "vnc=${VNC_DISPLAY},websocket=${VNC_WS_PORT}"
    -device ramfb

    # Monitor for QEMU control
    -monitor "telnet:localhost:${MONITOR_PORT},server,nowait,nodelay"

    # Daemonize
    -daemonize
    -D "$LOG_FILE"
    -pidfile "$PID_FILE"
    -name "${VM_NAME},process=${VM_NAME},debug-threads=on"

    # Serial console (useful for server)
    -serial pty

    # USB controller + input devices
    -device "qemu-xhci,id=xhci,p2=7,p3=7"
    -device usb-kbd
    -device usb-tablet

    # Network: TAP interface (same bridge as Windows for VM-to-VM communication)
    -netdev "tap,id=hostnet0,ifname=${TAP_NAME},script=no,downscript=no"
    -device "virtio-net-pci,id=net0,netdev=hostnet0,romfile=,mac=${MAC_ADDR}"

    # Boot disk: virtio-blk (native Linux support, simpler than virtio-scsi)
    -drive "file=${DISK_FILE},id=disk0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none"
    -device "virtio-blk-pci,drive=disk0,bootindex=1"

    # RTC
    -rtc base=localtime

    # UEFI firmware
    -drive "file=${UEFI_ROM},if=pflash,unit=0,format=raw,readonly=on"
    -drive "file=${VARS_FILE},if=pflash,unit=1,format=raw"

    # Random number generator
    -object "rng-random,id=objrng0,filename=/dev/urandom"
    -device "virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0"
)

# Add ISO for installation if requested
if [[ "$1" == "install" ]]; then
    if [[ ! -f "$ISO_FILE" ]]; then
        echo "ISO not found: $ISO_FILE"
        exit 1
    fi

    # Check for cloud-init ISO for automated install
    if [[ -f "$CLOUD_INIT_ISO" ]]; then
        echo "Starting Ubuntu VM with AUTOMATED installation..."
        echo "  (cloud-init will configure: hostname, user, SSH keys, network)"
        QEMU_CMD+=(
            # Installation ISO
            -drive "file=${ISO_FILE},id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none"
            -device "usb-storage,drive=cdrom0,bootindex=0,removable=on"
            # Cloud-init ISO for autoinstall
            -drive "file=${CLOUD_INIT_ISO},id=cidata,format=raw,readonly=on,media=cdrom,if=none"
            -device "usb-storage,drive=cidata,removable=on"
        )
    else
        echo "Starting Ubuntu VM with MANUAL installation..."
        echo "  (run setup-ubuntu-vm.sh to enable automated install)"
        QEMU_CMD+=(
            -drive "file=${ISO_FILE},id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none"
            -device "usb-storage,drive=cdrom0,bootindex=0,removable=on"
        )
    fi
else
    echo "Starting Ubuntu VM (normal boot)..."
fi

# Execute
"${QEMU_CMD[@]}"

sleep 1

if [[ -f "$PID_FILE" ]]; then
    echo ""
    echo "Ubuntu VM started (PID: $(cat $PID_FILE))"
    echo ""
    echo "Access:"
    echo "  VNC:       localhost${VNC_DISPLAY} (port 590${VNC_DISPLAY#:})"
    echo "  WebSocket: ws://localhost:${VNC_WS_PORT}"
    echo "  Monitor:   telnet localhost ${MONITOR_PORT}"
    echo "  Logs:      tail -f ${LOG_FILE}"
    echo ""
    if [[ "$1" == "install" && -f "$CLOUD_INIT_ISO" ]]; then
        echo "Automated install in progress. After completion:"
        echo "  SSH:       ssh ubu1  (192.168.50.10)"
        echo "  User:      steve"
        echo "  Password:  ubuntu (change recommended)"
    fi
    echo ""
    echo "Serial console PTY:"
    grep -o '/dev/pts/[0-9]*' "$LOG_FILE" | tail -1 || echo "  Check $LOG_FILE"
else
    echo "Failed to start VM. Check $LOG_FILE for errors."
    exit 1
fi
