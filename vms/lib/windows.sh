#!/bin/bash
# Windows VM Overlay Lifecycle
# Base image + copy-on-write overlay pattern for instant Windows VMs
#
# Usage: source this file, then call the functions.
# Requires: lib/network.sh, lib/detect.sh to be sourced first.

BASE_IMAGE_DIR="${BASE_IMAGE_DIR:-${STORAGE_DIR}/base-images}"
BASE_WINDOWS_DISK="${BASE_IMAGE_DIR}/windows-test.qcow2"
BASE_WINDOWS_VARS="${BASE_IMAGE_DIR}/windows-test.vars"
BASE_WINDOWS_ROM="${BASE_IMAGE_DIR}/windows-test.rom"
# Answer file lives in the repo, not the storage directory
AUTOUNATTEND_XML="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/base-images/autounattend.xml"
OVERLAY_DIR="${OVERLAY_DIR:-/tmp}"

# Default Windows VM settings
WIN_RAM="${WIN_RAM:-6G}"
WIN_CPUS="${WIN_CPUS:-4}"
WIN_USER="${WIN_USER:-testuser}"
WIN_SMBIOS_SERIAL="76XX5G4"

# ─── Base Image ───────────────────────────────────────────────────────

# Check base image is ready
# Returns 0 if all base image files present, 1 if any missing
windows_base_image_exists() {
    [[ -f "$BASE_WINDOWS_DISK" ]] && \
    [[ -f "$BASE_WINDOWS_VARS" ]] && \
    [[ -f "$BASE_WINDOWS_ROM" ]]
}

# Print base image status
windows_base_image_status() {
    echo "Base Image ($BASE_IMAGE_DIR)"
    if [[ -f "$BASE_WINDOWS_DISK" ]]; then
        local disk_size
        disk_size=$(du -h "$BASE_WINDOWS_DISK" 2>/dev/null | cut -f1)
        print_check 1 "Disk: windows-test.qcow2" "$disk_size"
    else
        print_check 0 "Disk: windows-test.qcow2" "missing"
    fi
    if [[ -f "$BASE_WINDOWS_VARS" ]]; then
        print_check 1 "UEFI vars: windows-test.vars"
    else
        print_check 0 "UEFI vars: windows-test.vars" "missing"
    fi
    if [[ -f "$BASE_WINDOWS_ROM" ]]; then
        print_check 1 "UEFI ROM: windows-test.rom"
    else
        print_check 0 "UEFI ROM: windows-test.rom" "missing"
    fi
}

# ─── Build Disk Seeding ───────────────────────────────────────────────

# Seed the build disk with a small FAT32 data partition containing
# Autounattend.xml. The partition uses type 0700 (basic data, not ESP)
# so that WinPE assigns it a drive letter and discovers the answer file.
# Windows Setup's WillWipeDisk=true wipes this partition later.
#
# Args: disk_path
seed_build_disk() {
    local disk_path="$1"

    if [[ ! -f "$AUTOUNATTEND_XML" ]]; then
        echo "    ERROR: Autounattend.xml not found: $AUTOUNATTEND_XML" >&2
        return 1
    fi

    echo "    Creating GPT with FAT data partition on build disk..."
    sgdisk -Z "$disk_path" >/dev/null 2>&1
    sgdisk -n 1:2048:+64M -t 1:0700 -c 1:SETUP "$disk_path" >/dev/null 2>&1

    local loop_dev
    loop_dev=$(losetup --find --show --offset $((2048*512)) --sizelimit $((64*1024*1024)) "$disk_path")
    mkfs.fat -F 32 -n SETUP "$loop_dev" >/dev/null

    local mnt
    mnt=$(mktemp -d)
    mount "$loop_dev" "$mnt"

    cp "$AUTOUNATTEND_XML" "$mnt/Autounattend.xml"

    umount "$mnt"
    rmdir "$mnt"
    losetup -d "$loop_dev"

    echo "    Seeded build disk with Autounattend.xml"
    return 0
}

# ─── Boot ESP Construction ────────────────────────────────────────────

# Build a bootable ESP disk with a BCD rewritten for hard-disk boot.
#
# The Windows ISO's BCD expects CD-ramdisk device class, so bootmgfw
# silently exits when launched from a non-CD context. This function
# extracts boot files from the ISO, rewrites the BCD device elements
# to reference a GPT partition, and packs everything into a FAT32 ESP.
#
# After cdboot on the ISO times out (~15s), firmware falls through to
# this ESP and boots Windows Setup deterministically — no input
# injection, no retry wrapper.
#
# Args: iso_path esp_output_path
# Requires: 7z, hivexsh, sgdisk, losetup, mkfs.fat
build_boot_esp() {
    local iso_path="$1"
    local esp_path="$2"
    local work
    work=$(mktemp -d)

    # Install missing dependencies automatically
    local missing_pkgs=()
    command -v 7z        >/dev/null 2>&1 || missing_pkgs+=(p7zip-full)
    command -v sgdisk    >/dev/null 2>&1 || missing_pkgs+=(gdisk)
    command -v mkfs.fat  >/dev/null 2>&1 || missing_pkgs+=(dosfstools)
    command -v tesseract >/dev/null 2>&1 || missing_pkgs+=(tesseract-ocr)
    if (( ${#missing_pkgs[@]} > 0 )); then
        echo "    Installing ${missing_pkgs[*]}..."
        apt-get install -y "${missing_pkgs[@]}"
    fi

    echo "    Extracting boot files from ISO..."
    7z e "$iso_path" -o"$work" \
        efi/boot/bootaa64.efi \
        boot/boot.sdi \
        sources/boot.wim \
        -aoa -bso0 -bsp0

    for f in bootaa64.efi boot.sdi boot.wim; do
        if [[ ! -f "$work/$f" ]]; then
            echo "    ERROR: $f not found in ISO" >&2
            rm -rf "$work"
            return 1
        fi
    done

    # Use the pre-built BCD that's been rewritten for partition boot.
    # It references ESP partition GUID F5F5F5F5-6A6A-7B7B-8C8C-9D9D9D9D9D9D
    # which must match the sgdisk -u flag below.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/base-images"
    local bcd_source="${script_dir}/bcd-esp.bin"
    if [[ ! -f "$bcd_source" ]]; then
        echo "    ERROR: Pre-built BCD not found: $bcd_source" >&2
        rm -rf "$work"
        return 1
    fi
    echo "    Using pre-built BCD for partition boot..."

    echo "    Building 2G ESP disk..."
    rm -f "$esp_path"
    truncate -s 2G "$esp_path"
    sgdisk -Z "$esp_path" >/dev/null 2>&1
    sgdisk -n 1:2048:+1900M -t 1:EF00 -c 1:ESP \
        -u 1:F5F5F5F5-6A6A-7B7B-8C8C-9D9D9D9D9D9D \
        "$esp_path" >/dev/null 2>&1

    local loop_dev
    loop_dev=$(losetup --find --show --offset $((2048*512)) \
        --sizelimit $((1900*1024*1024)) "$esp_path")
    mkfs.fat -F 32 -n ESP "$loop_dev" >/dev/null

    local mnt
    mnt=$(mktemp -d)
    mount "$loop_dev" "$mnt"

    mkdir -p "$mnt/EFI/BOOT" "$mnt/EFI/Microsoft/Boot" \
             "$mnt/boot" "$mnt/sources"
    cp "$work/bootaa64.efi" "$mnt/EFI/BOOT/BOOTAA64.EFI"
    cp "$bcd_source"         "$mnt/EFI/Microsoft/Boot/BCD"
    cp "$work/boot.sdi"      "$mnt/boot/boot.sdi"
    cp "$work/boot.wim"      "$mnt/sources/boot.wim"

    # Safety-net startup.nsh — only runs if firmware auto-boot fails
    # and drops to the embedded UEFI Shell. Tries multiple FS paths
    # since numbering depends on which devices are attached.
    cat > "$mnt/startup.nsh" << 'NSH'
@echo -off
map -r
FS0:\EFI\BOOT\BOOTAA64.EFI
FS1:\EFI\BOOT\BOOTAA64.EFI
FS2:\EFI\BOOT\BOOTAA64.EFI
FS3:\EFI\BOOT\BOOTAA64.EFI
FS4:\EFI\BOOT\BOOTAA64.EFI
NSH

    umount "$mnt"
    rmdir "$mnt"
    losetup -d "$loop_dev"
    rm -rf "$work"

    echo "    ESP built: $(du -h "$esp_path" | cut -f1)"
    return 0
}


# ─── Overlay Lifecycle ─────────────────────────────────────────────────

# Create instant overlay from base image
# Args: name
# Prints: overlay disk path
# Returns 1 if base image missing (caller should handle)
windows_overlay_create() {
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "Error: overlay name required" >&2
        return 1
    fi

    if ! windows_base_image_exists; then
        return 1
    fi

    local overlay_disk="${OVERLAY_DIR}/winvm-${name}.qcow2"
    local overlay_vars="${OVERLAY_DIR}/winvm-${name}.vars"

    # Create qcow2 overlay backed by base disk
    qemu-img create -f qcow2 -b "$BASE_WINDOWS_DISK" -F qcow2 "$overlay_disk"

    # Copy UEFI vars (writable per-VM state)
    cp "$BASE_WINDOWS_VARS" "$overlay_vars"

    echo "$overlay_disk"
    return 0
}

# Generate deterministic MAC from instance name
# Args: name
_windows_mac_for_name() {
    local name="$1"
    printf '02:%02x:%02x:%02x:%02x:%02x' \
        $(echo -n "winvm-${name}" | md5sum | sed 's/\(..\)/0x\1 /g' | head -c 30)
}

# ─── VM Control ────────────────────────────────────────────────────────

# Boot Windows VM from overlay
# Args: name, ip, [tap], [vnc_display], [monitor_port]
windows_vm_start() {
    local name="$1"
    local ip="$2"
    local tap="${3:-tap-win-${name}}"
    local vnc_display="${4:-:8}"
    local monitor_port="${5:-7198}"

    local overlay_disk="${OVERLAY_DIR}/winvm-${name}.qcow2"
    local overlay_vars="${OVERLAY_DIR}/winvm-${name}.vars"
    local pid_file="/run/shm/winvm-${name}.pid"
    local log_file="/run/shm/winvm-${name}.log"

    if [[ ! -f "$overlay_disk" ]]; then
        echo "Error: overlay not found: $overlay_disk" >&2
        echo "  Run: windows_overlay_create $name" >&2
        return 1
    fi

    # Derive VNC number and websocket port
    local vnc_num="${vnc_display#:}"
    local vnc_ws_port="57${vnc_num}"

    # Generate deterministic MAC
    local mac
    mac=$(_windows_mac_for_name "$name")

    # Ensure network infrastructure
    ensure_bridge "$BRIDGE_NAME" "$HOST_IP"
    ensure_tap "$tap" "$BRIDGE_NAME"

    echo "  Starting Windows VM 'winvm-${name}'..."

    qemu-system-aarch64 \
        -nodefaults \
        -cpu host \
        -smp "${WIN_CPUS},sockets=1,dies=1,cores=${WIN_CPUS},threads=1" \
        -m "$WIN_RAM" \
        -machine "type=virt,secure=off,gic-version=max,accel=kvm" \
        -enable-kvm \
        -smbios "type=1,serial=${WIN_SMBIOS_SERIAL}" \
        -display "vnc=${vnc_display},websocket=${vnc_ws_port}" \
        -device ramfb \
        -monitor "telnet:localhost:${monitor_port},server,nowait,nodelay" \
        -daemonize \
        -D "$log_file" \
        -pidfile "$pid_file" \
        -name "winvm-${name}" \
        -serial pty \
        -device "qemu-xhci" \
        -device usb-kbd \
        -device usb-tablet \
        -netdev "tap,id=hostnet0,ifname=${tap},script=no,downscript=no" \
        -device "virtio-net-pci,netdev=hostnet0,mac=${mac}" \
        -object "iothread,id=io0" \
        -drive "file=${overlay_disk},id=data0,format=qcow2,cache=writeback,aio=threads,discard=on,detect-zeroes=on,if=none" \
        -device "virtio-scsi-pci,id=scsi0,bus=pcie.0,iothread=io0" \
        -device "scsi-hd,drive=data0,bus=scsi0.0,bootindex=1" \
        -drive "file=${BASE_WINDOWS_ROM},if=pflash,unit=0,format=raw,readonly=on" \
        -drive "file=${overlay_vars},if=pflash,unit=1,format=raw" \
        -object "rng-random,id=rng0,filename=/dev/urandom" \
        -device "virtio-rng-pci,rng=rng0" \
        -rtc base=localtime

    sleep 1

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        echo "  QEMU started (PID: $pid)"
        echo "  VNC available at localhost${vnc_display}"
        return 0
    else
        echo "  Failed to start VM. Check $log_file" >&2
        return 1
    fi
}

# Wait for Windows SSH to become accessible
# Args: ip, [user], [max_attempts]
windows_vm_wait_ssh() {
    local ip="$1"
    local user="${2:-$WIN_USER}"
    local max_attempts="${3:-90}"

    echo "  Waiting for SSH at ${user}@${ip} (up to ${max_attempts} attempts)..."
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
               "${user}@${ip}" "echo ready" 2>/dev/null | grep -q ready; then
            echo ""
            echo "  SSH connected!"
            return 0
        fi
        printf "."
        ((attempt++))
        sleep 2
    done
    echo ""
    echo "  SSH not accessible after ${max_attempts} attempts" >&2
    return 1
}

# Run a command on the Windows VM via SSH
# Args: ip, cmd, [user]
windows_vm_exec() {
    local ip="$1"
    local cmd="$2"
    local user="${3:-$WIN_USER}"

    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${user}@${ip}" "${cmd}"
}

# Graceful shutdown of Windows VM
# Args: name, [monitor_port]
windows_vm_stop() {
    local name="$1"
    local monitor_port="${2:-7198}"
    local pid_file="/run/shm/winvm-${name}.pid"

    if [[ ! -f "$pid_file" ]]; then
        echo "  VM 'winvm-${name}' is not running (no PID file)"
        return 0
    fi

    local pid
    pid=$(cat "$pid_file")

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "  VM 'winvm-${name}' not running (stale PID file)"
        rm -f "$pid_file"
        return 0
    fi

    echo "  Sending ACPI shutdown to winvm-${name}..."
    echo "system_powerdown" | nc -q1 localhost "$monitor_port" 2>/dev/null || true

    echo "  Waiting for VM to shut down (max 60s for Windows)..."
    for i in {1..60}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  VM shut down cleanly"
            rm -f "$pid_file"
            return 0
        fi
        sleep 1
    done

    echo "  VM didn't respond, forcing quit..."
    echo "quit" | nc -q1 localhost "$monitor_port" 2>/dev/null || kill "$pid" 2>/dev/null || true

    sleep 2
    rm -f "$pid_file"
    echo "  Done"
}

# Full teardown: stop VM, delete overlay, clean up
# Args: name, [tap], [monitor_port]
windows_vm_destroy() {
    local name="$1"
    local tap="${2:-tap-win-${name}}"
    local monitor_port="${3:-7198}"
    local pid_file="/run/shm/winvm-${name}.pid"
    local log_file="/run/shm/winvm-${name}.log"
    local overlay_disk="${OVERLAY_DIR}/winvm-${name}.qcow2"
    local overlay_vars="${OVERLAY_DIR}/winvm-${name}.vars"

    # Stop VM if running
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            windows_vm_stop "$name" "$monitor_port"
        fi
    fi

    # Delete overlay files
    if [[ -f "$overlay_disk" ]]; then
        rm -f "$overlay_disk"
        echo "  Removed: $overlay_disk"
    fi
    if [[ -f "$overlay_vars" ]]; then
        rm -f "$overlay_vars"
        echo "  Removed: $overlay_vars"
    fi

    # Remove TAP interface
    if ip link show "$tap" &>/dev/null; then
        ip link set "$tap" down 2>/dev/null || true
        ip link delete "$tap" 2>/dev/null || true
        echo "  Removed TAP: $tap"
    fi

    # Clean up runtime files
    rm -f "$pid_file" "$log_file"
    echo "  Cleaned up runtime files"
}

# Check VM state and print status
# Args: name, ip, [user]
windows_vm_status() {
    local name="$1"
    local ip="$2"
    local user="${3:-$WIN_USER}"
    local pid_file="/run/shm/winvm-${name}.pid"
    local overlay_disk="${OVERLAY_DIR}/winvm-${name}.qcow2"
    local overlay_vars="${OVERLAY_DIR}/winvm-${name}.vars"

    echo ""
    echo "Windows VM: winvm-${name}"
    echo "-------------------------------------------------------"

    # Base image
    windows_base_image_status
    echo ""

    # Overlay
    echo "Overlay ($OVERLAY_DIR)"
    if [[ -f "$overlay_disk" ]]; then
        local overlay_size
        overlay_size=$(du -h "$overlay_disk" 2>/dev/null | cut -f1)
        print_check 1 "Disk overlay: winvm-${name}.qcow2" "$overlay_size"
    else
        print_check 0 "Disk overlay: winvm-${name}.qcow2" "not created"
    fi
    if [[ -f "$overlay_vars" ]]; then
        print_check 1 "UEFI vars: winvm-${name}.vars"
    else
        print_check 0 "UEFI vars: winvm-${name}.vars" "not created"
    fi
    echo ""

    # Runtime
    echo "Runtime"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        local pid
        pid=$(cat "$pid_file")
        print_check 1 "VM process: running" "PID $pid"

        if ping -c1 -W2 "$ip" &>/dev/null; then
            print_check 1 "Network: $ip reachable"
        else
            print_check 0 "Network: $ip not reachable"
        fi

        if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
               "${user}@${ip}" "echo ready" 2>/dev/null | grep -q ready; then
            print_check 1 "SSH: accessible" "ssh ${user}@${ip}"
        else
            print_check 0 "SSH: not accessible"
        fi
    else
        print_check 0 "VM process: not running"
    fi
    echo ""
}
