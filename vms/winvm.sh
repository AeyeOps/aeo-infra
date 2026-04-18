#!/bin/bash
# Windows VM Management
# Uses base image + copy-on-write overlays for instant, disposable Windows VMs
#
# Usage:
#   ./winvm.sh start <name> [--ip IP]    Start a new Windows VM (auto-builds base image if needed)
#   ./winvm.sh stop <name>               Graceful shutdown
#   ./winvm.sh destroy <name>            Full teardown (stop + delete overlay)
#   ./winvm.sh ssh <name>                Connect via SSH
#   ./winvm.sh exec <name> <cmd>         Run command on VM via SSH
#   ./winvm.sh status <name>             Check VM state
#   ./winvm.sh list                      List running Windows VMs
#   ./winvm.sh image build               Build base image (interactive, one-time)
#   ./winvm.sh image status              Check if base image exists
#   ./winvm.sh image destroy             Remove base image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Global defaults (must be set before sourcing libs that reference them)
STORAGE_DIR="${STORAGE_DIR:-${SCRIPT_DIR}/.images}"

# Source library functions
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/windows.sh"
BRIDGE_NAME="br-vm"
VM_SUBNET="192.168.50"
HOST_IP="${VM_SUBNET}.1"

# ─── Usage ─────────────────────────────────────────────────────────────

show_usage() {
    cat << 'EOF'
Usage: ./winvm.sh <command> [args]

Instance commands:
  start <name>              Start a new Windows VM (auto-builds base image if needed)
  stop <name>               Graceful shutdown
  destroy <name>            Full teardown (stop + delete overlay)
  ssh <name>                Connect via SSH
  exec <name> <cmd>         Run command on VM via SSH
  status <name>             Check VM state
  ip <name>                 Print the DHCP-assigned IP of a running VM
  list                      List running Windows VMs

Base image commands:
  image build               Build base image (interactive, one-time)
  image status              Check if base image exists
  image destroy             Remove base image

Options:
  --help, -h    Show this help

Examples:
  ./winvm.sh start meshtest            # Instant Windows VM (builds base image if needed)
  ./winvm.sh ssh meshtest              # SSH into it
  ./winvm.sh exec meshtest "hostname"  # Run a command
  ./winvm.sh destroy meshtest          # Tear it down
  ./winvm.sh image build               # Manually (re)build base image
EOF
}

# ─── Helpers ───────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This action requires root privileges (sudo)"
        exit 1
    fi
}

# ─── Commands ──────────────────────────────────────────────────────────

cmd_start() {
    local name="$1"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    require_root

    echo ""
    echo "Windows VM: winvm-${name}"
    echo "======================================================="
    echo ""

    # Auto-build base image if missing
    if ! windows_base_image_exists; then
        echo "  Base image not found at $BASE_IMAGE_DIR"
        echo "  Building base image first..."
        echo ""
        cmd_image_build
        echo ""
        echo "Continuing with VM start..."
        echo ""
    fi
    echo "  Base image OK"

    # Check if overlay already exists (VM might already be running)
    local pid_file="/run/shm/winvm-${name}.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        echo "  VM 'winvm-${name}' is already running (PID: $(cat "$pid_file"))"
        exit 1
    fi

    # Create overlay
    echo "  Creating overlay..."
    local overlay_disk
    overlay_disk=$(windows_overlay_create "$name")
    echo "  Overlay: $overlay_disk"
    echo ""

    # Ensure network (bridge, tap, NAT, dnsmasq DHCP)
    local tap="tap-win-${name}"
    local upstream
    upstream=$(detect_upstream_interface)
    ensure_bridge "$BRIDGE_NAME" "$HOST_IP"
    ensure_tap "$tap" "$BRIDGE_NAME"
    ensure_ip_forwarding
    ensure_nat_masquerade "$upstream"
    ensure_forward_rules "$BRIDGE_NAME" "$upstream"
    ensure_dnsmasq_on_bridge "$BRIDGE_NAME"
    echo ""

    # Start VM
    windows_vm_start "$name" "" "$tap"
    echo ""

    # Wait for DHCP lease, then SSH
    echo "  Waiting for DHCP lease..."
    local ip
    ip=$(windows_vm_lease "$name" 180)
    if [[ -z "$ip" ]]; then
        echo "  ERROR: no DHCP lease for winvm-${name} within 180s" >&2
        exit 1
    fi
    echo "  Lease: $ip"
    windows_vm_wait_ssh "$ip"

    echo ""
    echo "======================================================="
    echo "Windows VM 'winvm-${name}' ready"
    echo ""
    echo "  IP:   ${ip}"
    echo "  SSH:  ssh ${WIN_USER}@${ip}"
    echo "  VNC:  localhost:8 (port 5908)"
    echo ""
}

cmd_ip() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "Usage: winvm.sh ip <name>" >&2
        exit 1
    fi
    local ip
    ip=$(windows_vm_lease "$name" 0 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        echo "No DHCP lease for winvm-${name}" >&2
        exit 1
    fi
    printf '%s\n' "$ip"
}

cmd_stop() {
    local name="$1"
    require_root

    echo "Stopping Windows VM 'winvm-${name}'..."
    windows_vm_stop "$name"
}

cmd_destroy() {
    local name="$1"
    require_root

    echo "Destroying Windows VM 'winvm-${name}'..."
    echo "  This will delete the overlay (base image is preserved)"
    echo ""

    windows_vm_destroy "$name"

    echo ""
    echo "VM 'winvm-${name}' destroyed (base image untouched)"
}

cmd_ssh() {
    local name="$1"
    local ip
    ip=$(windows_vm_lease "$name" 5 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        echo "Error: no DHCP lease for winvm-${name}" >&2
        exit 1
    fi

    exec ssh -o StrictHostKeyChecking=accept-new "${WIN_USER}@${ip}"
}

cmd_exec() {
    local name="$1"
    shift
    local ip
    ip=$(windows_vm_lease "$name" 5 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
        echo "Error: no DHCP lease for winvm-${name}" >&2
        exit 1
    fi

    windows_vm_exec "$ip" "$*"
}

cmd_status() {
    local name="$1"
    local ip
    ip=$(windows_vm_lease "$name" 0 2>/dev/null || true)
    ip="${ip:-unknown}"

    windows_vm_status "$name" "$ip"
}

cmd_list() {
    echo "Running Windows VMs:"
    echo ""
    printf "%-20s %-8s %-20s\n" "NAME" "PID" "OVERLAY"
    printf "%-20s %-8s %-20s\n" "----" "---" "-------"

    local found=0
    for pid_file in /run/shm/winvm-*.pid; do
        [[ -f "$pid_file" ]] || continue
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            local basename
            basename=$(basename "$pid_file" .pid)
            local name="${basename#winvm-}"
            local overlay="${OVERLAY_DIR}/winvm-${name}.qcow2"
            local overlay_size=""
            if [[ -f "$overlay" ]]; then
                overlay_size=$(du -h "$overlay" 2>/dev/null | cut -f1)
            fi
            printf "%-20s %-8s %-20s\n" "winvm-${name}" "$pid" "$overlay_size"
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "  (none)"
    fi
}

# ─── Base Image ───────────────────────────────────────────────────────

cmd_image_status() {
    echo ""
    windows_base_image_status
    echo ""
    if windows_base_image_exists; then
        echo "Base image is ready."
    else
        echo "Base image not found."
        echo "  Run: sudo ./winvm.sh image build"
    fi
}

cmd_image_destroy() {
    require_root

    if ! windows_base_image_exists; then
        echo "Base image not found (nothing to destroy)"
        return 0
    fi

    echo "This will permanently delete the base image:"
    echo "  $BASE_WINDOWS_DISK"
    echo "  $BASE_WINDOWS_VARS"
    echo "  $BASE_WINDOWS_ROM"
    echo ""
    read -p "Type 'destroy' to confirm: " confirm

    if [[ "$confirm" != "destroy" ]]; then
        echo "Cancelled"
        return 1
    fi

    rm -f "$BASE_WINDOWS_DISK" "$BASE_WINDOWS_VARS" "$BASE_WINDOWS_ROM"
    echo "Base image destroyed"
}

cmd_image_build() {
    require_root

    local iso_file="${STORAGE_DIR}/win11arm64.iso"
    local virtio_iso="${STORAGE_DIR}/virtio-win.iso"
    local build_disk="${STORAGE_DIR}/base-build-windows.img"
    local build_vars="${STORAGE_DIR}/base-build-windows.vars"
    local build_rom="${STORAGE_DIR}/base-build-windows.rom"
    local build_esp="${STORAGE_DIR}/base-build-windows-esp.img"
    local build_usb="${STORAGE_DIR}/base-build-windows-usb.img"
    local build_pid="/run/shm/base-build-windows.pid"
    local build_log="/run/shm/base-build-windows.log"
    local build_tap="tap-win-build"
    local build_vnc=":9"
    local build_vnc_ws="5709"
    local build_monitor="7199"
    local build_mac="02:aa:bb:cc:dd:ee"
    local build_timeout=10800  # 3h soft cap; we warn but do not kill
    local stall_threshold=600  # warn if build disk unchanged for 10 min
    local verify_pid="/run/shm/winvm-base-verify.pid"
    local verify_log="/run/shm/winvm-base-verify.log"

    echo ""
    echo "Windows Base Image Builder (unattended)"
    echo "======================================================="
    echo ""

    # Check for existing base image
    if windows_base_image_exists; then
        echo "Base image already exists at $BASE_IMAGE_DIR"
        echo "  To rebuild, first run: sudo ./winvm.sh image destroy"
        exit 1
    fi

    # Clean up any leftover build state from a previous failed run
    if [[ -f "$build_pid" ]]; then
        local old_pid
        old_pid=$(cat "$build_pid")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "  Killing leftover build QEMU (PID $old_pid)..."
            kill -9 "$old_pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    # Also kill by name in case PID file was already deleted
    local stale_pid
    stale_pid=$(pgrep -f "qemu-system.*base-build-windows" 2>/dev/null || true)
    if [[ -n "$stale_pid" ]]; then
        echo "  Killing stale build QEMU (PID $stale_pid)..."
        kill -9 $stale_pid 2>/dev/null || true
        sleep 1
    fi
    if [[ -f "$verify_pid" ]]; then
        local old_verify_pid
        old_verify_pid=$(cat "$verify_pid")
        if kill -0 "$old_verify_pid" 2>/dev/null; then
            echo "  Killing leftover verify QEMU (PID $old_verify_pid)..."
            kill -9 "$old_verify_pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    stale_pid=$(pgrep -f "qemu-system.*winvm-base-verify" 2>/dev/null || true)
    if [[ -n "$stale_pid" ]]; then
        echo "  Killing stale verify QEMU (PID $stale_pid)..."
        kill -9 $stale_pid 2>/dev/null || true
        sleep 1
    fi
    rm -f "$build_pid" "$build_log" \
          "$build_disk" "$build_vars" "$build_rom" "$build_esp" "$build_usb" \
          "$verify_pid" "$verify_log"

    # Check for Windows ISO
    if [[ ! -f "$iso_file" ]]; then
        echo "Windows ARM64 ISO not found at: $iso_file"
        echo ""
        echo "Download Windows 11 ARM64 ISO and place it at:"
        echo "  $iso_file"
        echo ""
        echo "Download from:"
        echo "  https://www.microsoft.com/software-download/windows11"
        echo "  (Select 'Windows 11 (multi-edition ISO for Arm64)')"
        exit 1
    fi

    # Check for VirtIO drivers ISO
    if [[ ! -f "$virtio_iso" ]]; then
        echo "VirtIO drivers ISO not found at: $virtio_iso"
        echo ""
        echo "Download from:"
        echo "  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
        exit 1
    fi

    echo "  Windows ISO:  $iso_file"
    echo "  VirtIO ISO:   $virtio_iso"
    echo ""

    # Create base image directory
    mkdir -p "$BASE_IMAGE_DIR"

    echo "Rendering Autounattend.xml..."
    if ! prepare_windows_autounattend; then
        echo "Failed to render Autounattend.xml. Cannot proceed." >&2
        exit 1
    fi

    # Create build disk with startup.nsh + Autounattend.xml
    echo "Creating 32G build disk..."
    qemu-img create -f raw "$build_disk" 32G
    if ! seed_build_disk "$build_disk"; then
        echo "Failed to seed build disk. Cannot proceed." >&2
        exit 1
    fi

    # Build boot ESP with BCD rewritten for hard-disk boot.
    # The Windows ISO's BCD expects CD-ramdisk device class; bootmgfw
    # silently exits from non-CD contexts. This ESP carries bootmgfw +
    # a rewritten BCD that resolves boot.wim from a GPT partition.
    # After cdboot on the ISO times out (~15s), firmware auto-boots
    # the ESP — no input injection needed.
    echo "Building boot ESP (BCD rewrite)..."
    if ! build_boot_esp "$iso_file" "$build_esp"; then
        echo "Failed to build boot ESP. Cannot proceed." >&2
        exit 1
    fi

    # Create USB image with Autounattend.xml for WinPE discovery.
    # WinPE cannot see the virtio-scsi build disk until VirtIO drivers are
    # loaded, but the drivers are specified IN the answer file — chicken-and-egg.
    # This USB image delivers the answer file on a removable medium WinPE
    # can see natively.
    echo "Creating Autounattend USB image..."
    truncate -s 32M "$build_usb"
    mkfs.fat -F 16 -n ANSWER "$build_usb" >/dev/null
    local usb_mnt
    usb_mnt=$(mktemp -d)
    mount "$build_usb" "$usb_mnt"
    cp "$AUTOUNATTEND_XML" "$usb_mnt/Autounattend.xml"
    umount "$usb_mnt"
    rmdir "$usb_mnt"
    echo "  Autounattend USB ready"

    # Create UEFI files.
    # IMPORTANT: `truncate -s 64M` on an already-64 MiB file is a no-op; it
    # leaves the file contents intact. For a build we ALWAYS want a fresh
    # NVRAM — stale boot variables from a previous failed build will poison
    # TianoCore's boot-option retry behavior (cdboot.efi appears to hang,
    # HARDDISK bootmgfw enters an infinite loop, etc.). See
    # vms/base-images/BOOT.md "NVRAM wipe" for the multi-day debug that
    # found this.
    echo "Creating UEFI firmware files..."
    # Prefer the full 64 MiB AAVMF code/vars pair when available. Using the
    # packaged vars template gives us a real edk2 variable store instead of a
    # zero-filled blob, while still keeping per-build NVRAM fresh.
    local uefi_source=""
    local uefi_vars_template=""
    if [[ -f /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd &&
          -f /usr/share/AAVMF/AAVMF_VARS.fd ]]; then
        uefi_source="/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd"
        uefi_vars_template="/usr/share/AAVMF/AAVMF_VARS.fd"
    elif [[ -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]]; then
        uefi_source="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
    else
        echo "  ERROR: No ARM64 UEFI firmware found (expected AAVMF or QEMU_EFI.fd)." >&2
        exit 1
    fi
    rm -f "$build_rom" "$build_vars"
    if [[ -n "$uefi_vars_template" ]]; then
        cp "$uefi_source" "$build_rom"
        cp "$uefi_vars_template" "$build_vars"
    else
        truncate -s 64M "$build_rom"
        dd if="$uefi_source" of="$build_rom" conv=notrunc 2>/dev/null
        truncate -s 64M "$build_vars"
    fi

    # Ensure network
    local upstream
    upstream=$(detect_upstream_interface)
    ensure_bridge "$BRIDGE_NAME" "$HOST_IP"
    ensure_tap "$build_tap" "$BRIDGE_NAME"
    ensure_ip_forwarding
    ensure_nat_masquerade "$upstream"
    ensure_forward_rules "$BRIDGE_NAME" "$upstream"
    ensure_dnsmasq_on_bridge "$BRIDGE_NAME"

    local qemu_cpuset qemu_cpuset_reason
    qemu_cpuset="$(windows_qemu_cpuset)"
    qemu_cpuset_reason="$(windows_qemu_cpuset_reason)"
    if [[ -n "$qemu_cpuset" ]]; then
        echo "Pinning QEMU to homogeneous host CPUs: ${qemu_cpuset} (${qemu_cpuset_reason})"
    fi

    # Sparse-aware allocated-bytes helper.
    # If the file is missing, emits a loud warning to stderr once and returns "".
    # Callers must handle empty results (e.g., skip arithmetic).
    _disk_allocated_bytes() {
        if [[ ! -e "$1" ]]; then
            echo "[!] DISK FILE MISSING: $1" >&2
            return 1
        fi
        du --block-size=1 "$1" 2>/dev/null | cut -f1
    }

    # Return success once the target disk's ESP contains the Windows boot
    # files created by bcdboot. This keeps Phase 1 attached until the
    # installed disk can stand on its own.
    _target_esp_has_boot_files() {
        local disk_path="$1"
        local start sectors
        read -r start sectors < <(partx -g -o START,SECTORS --raw --nr 1 "$disk_path" 2>/dev/null | awk 'NR==1 {print $1, $2}')
        [[ -n "${start:-}" && -n "${sectors:-}" ]] || return 1

        local loop_dev="" mnt="" ret=1
        loop_dev=$(losetup --find --show -r \
            --offset $((start * 512)) \
            --sizelimit $((sectors * 512)) \
            "$disk_path" 2>/dev/null) || return 1
        mnt=$(mktemp -d)

        if mount -o ro "$loop_dev" "$mnt" >/dev/null 2>&1; then
            if [[ -f "$mnt/EFI/Microsoft/Boot/bootmgfw.efi" &&
                  -f "$mnt/EFI/Microsoft/Boot/BCD" &&
                  -f "$mnt/EFI/Boot/bootaa64.efi" ]]; then
                ret=0
            fi
            umount "$mnt" >/dev/null 2>&1 || true
        fi

        rmdir "$mnt" >/dev/null 2>&1 || true
        losetup -d "$loop_dev" >/dev/null 2>&1 || true
        return "$ret"
    }

    local screen_dir="${STORAGE_DIR}/winbuild-latest"
    rm -rf "$screen_dir"
    mkdir -p "$screen_dir"
    local screen_ppm="${screen_dir}/latest.ppm"
    local vnc_tool
    vnc_tool="$(cd "$(dirname "$0")" && pwd)/base-images/vnc_full.py"
    local vnc_send_tool
    vnc_send_tool="$(cd "$(dirname "$0")" && pwd)/base-images/vnc_send_keys.py"
    local vnc_spam_tool
    vnc_spam_tool="$(cd "$(dirname "$0")" && pwd)/base-images/vnc_spam_keys.py"
    local vnc_click_tool
    vnc_click_tool="$(cd "$(dirname "$0")" && pwd)/base-images/vnc_click.py"
    local vnc_port
    vnc_port=$(( 5900 + ${build_vnc#:} ))  # :9 → 5909
    local stall_warned=0

    # Capture a timestamped screenshot + OCR, return OCR text in $__ocr_text
    _capture_screen() {
        __ocr_text=""
        if [[ ! -f "$vnc_tool" ]]; then return; fi
        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        local ppm="${screen_dir}/${ts}.ppm"
        local png="${screen_dir}/${ts}.png"
        python3 "$vnc_tool" --host 127.0.0.1 --port "$vnc_port" \
            --screenshot "$ppm" 2>/dev/null || return 0
        python3 -c "from PIL import Image; Image.open('$ppm').save('$png')" 2>/dev/null || return 0
        rm -f "$ppm"  # keep only PNG
        # symlink latest for easy viewing
        ln -sf "$png" "${screen_dir}/latest.png"
        if command -v tesseract >/dev/null 2>&1 && [[ -f "$png" ]]; then
            __ocr_text=$(tesseract "$png" stdout 2>/dev/null || true)
        fi
    }

    _dialog_crop_ocr() {
        local png_path="$1"
        [[ -f "$png_path" ]] || return 0
        local crop_path="${png_path%.png}-dialog.png"
        python3 - "$png_path" "$crop_path" <<'PY' >/dev/null 2>&1
from PIL import Image, ImageOps, ImageEnhance
import sys
src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src)
w, h = img.size
box = (w // 4, h // 4, 3 * w // 4, 3 * h // 4)
crop = img.crop(box).convert("L")
crop = ImageOps.autocontrast(crop)
crop = ImageEnhance.Contrast(crop).enhance(2.5)
crop = crop.point(lambda p: 255 if p > 165 else 0)
crop.save(dst)
PY
        if command -v tesseract >/dev/null 2>&1 && [[ -f "$crop_path" ]]; then
            tesseract "$crop_path" stdout --psm 6 2>/dev/null || true
        fi
    }

    _start_phase1_qemu() {
        windows_qemu_aarch64 \
            -nodefaults \
            -cpu host \
            -smp "${WIN_CPUS},sockets=1,dies=1,cores=${WIN_CPUS},threads=1" \
            -m "$WIN_RAM" \
            -machine "type=virt,secure=off,gic-version=max,accel=kvm" \
            -enable-kvm \
            -smbios "type=1,serial=${WIN_SMBIOS_SERIAL}" \
            -display "vnc=${build_vnc},websocket=${build_vnc_ws}" \
            -device ramfb \
            -monitor "telnet:localhost:${build_monitor},server,nowait,nodelay" \
            -daemonize \
            -D "$build_log" \
            -pidfile "$build_pid" \
            -name "base-build-windows" \
            -serial pty \
            -device "qemu-xhci" \
            -device usb-kbd \
            -device usb-tablet \
            -netdev "tap,id=hostnet0,ifname=${build_tap},script=no,downscript=no" \
            -device "virtio-net-pci,netdev=hostnet0,mac=${build_mac}" \
            -drive "file=${iso_file},id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
            -device "usb-storage,drive=cdrom0,removable=on" \
            -drive "file=${virtio_iso},id=virtio0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
            -device "usb-storage,drive=virtio0,removable=on" \
            -drive "file=${build_usb},id=answer0,format=raw,cache=unsafe,readonly=on,if=none" \
            -device "usb-storage,drive=answer0,removable=on" \
            -object "iothread,id=io0" \
            -device "virtio-scsi-pci,id=scsi0,bus=pcie.0,iothread=io0" \
            -drive "file=${build_esp},id=esp0,format=raw,cache=unsafe,if=none" \
            -device "scsi-hd,id=buildesp,drive=esp0,bus=scsi0.0,lun=0" \
            -drive "file=${build_disk},id=data0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none" \
            -device "scsi-hd,id=builddata,drive=data0,bus=scsi0.0,lun=1" \
            -drive "file=${build_rom},if=pflash,unit=0,format=raw,readonly=on" \
            -drive "file=${build_vars},if=pflash,unit=1,format=raw" \
            -object "rng-random,id=rng0,filename=/dev/urandom" \
            -device "virtio-rng-pci,rng=rng0" \
            -rtc base=localtime

        local pid_wait=0
        while [[ ! -f "$build_pid" ]] && (( pid_wait < 10 )); do
            sleep 1
            pid_wait=$((pid_wait + 1))
        done

        if [[ ! -f "$build_pid" ]]; then
            echo "Failed to start QEMU for phase 1 (no PID file after ${pid_wait}s). Check $build_log"
            return 1
        fi

        pid=$(cat "$build_pid")
        echo "  QEMU started (PID: $pid)"
        echo "  Boot path: cdboot timeout (~15s) → ESP → bootmgfw → WinPE"
        return 0
    }

    _detach_phase1_helper_esp() {
        local response
        response=$(printf 'device_del buildesp\n' | nc -q1 localhost "$build_monitor" 2>/dev/null | strings || true)
        sleep 1
        if printf 'info block\n' | nc -q1 localhost "$build_monitor" 2>/dev/null | strings | grep -q '^esp0 '; then
            echo "  [!] Failed to detach temporary helper ESP via device_del buildesp"
            [[ -n "$response" ]] && echo "$response" | sed 's/^/  [!]   /'
            return 1
        fi
        echo "  [*] Detached temporary helper ESP after WinPE load."
        return 0
    }

    # ── PHASE 1: Boot WinPE from ESP, extract Windows image ─────────────
    #
    # The ESP disk carries bootmgfw + a BCD rewritten for partition boot.
    # cdboot on the USB ISO times out after ~15s, then firmware falls
    # through to the ESP on SCSI and auto-boots bootmgfw. bootmgfw reads
    # the rewritten BCD, loads boot.wim as a RAM disk, and starts WinPE.
    #
    # WinPE discovers Autounattend.xml on the build disk's data partition,
    # finds install.wim on the USB ISO, partitions the build disk, extracts
    # the image, and reboots.
    #
    # No input injection (QMP/VNC) needed.
    # bootmgfw on ARM64 QEMU has a non-deterministic startup — it
    # silently exits ~50% of the time. Retry up to 3 times with
    # fresh NVRAM each attempt.

    local boot_ok=0
    local max_boot_attempts=10
    for boot_attempt in $(seq 1 $max_boot_attempts); do
    echo ""
    echo "Phase 1: Booting WinPE from ESP (attempt $boot_attempt/$max_boot_attempts)..."
    echo ""

    # Fresh NVRAM for each attempt
    rm -f "$build_vars"
    if [[ -n "$uefi_vars_template" ]]; then
        cp "$uefi_vars_template" "$build_vars"
    else
        truncate -s 64M "$build_vars"
    fi

    local pid
    if ! _start_phase1_qemu; then
        exit 1
    fi

    # Wait up to 90s for boot.wim to start loading (disk grows beyond 2MB).
    # bootmgfw on ARM64 QEMU silently exits ~50% of the time; detect this
    # and retry rather than waiting forever.
    echo "  Waiting for WinPE to load (up to 90s)..."
    local boot_wait=0
    local boot_detected=0
    local cdboot_prompt_handled=0
    while (( boot_wait < 90 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  QEMU exited unexpectedly during boot wait"
            break
        fi
        local check_bytes
        check_bytes=$(_disk_allocated_bytes "$build_disk")
        if (( check_bytes > 2*1024*1024 )); then
            echo "  WinPE boot detected (disk=${check_bytes} bytes)"
            boot_detected=1
            break
        fi
        # Screenshot + OCR every 10s
        if (( boot_wait > 0 && boot_wait % 10 == 0 )); then
            _capture_screen
            if [[ -n "$__ocr_text" ]]; then
                echo "  --- OCR @${boot_wait}s ---"
                echo "$__ocr_text" | sed '/^$/d' | head -5 | sed 's/^/  | /'
                echo "  ---"
            fi
            if (( cdboot_prompt_handled == 0 )) &&
               echo "$__ocr_text" | grep -qi "Press any key to boot from CD or DVD" &&
               [[ -f "$vnc_spam_tool" || -f "$vnc_send_tool" ]]; then
                echo "  [*] cdboot prompt detected; sending Space spam to advance into Windows Setup..."
                if [[ -f "$vnc_spam_tool" ]]; then
                    python3 "$vnc_spam_tool" --host 127.0.0.1 --port "$vnc_port" \
                        --key Space --duration 15 --rate 8 --hold-ms 60 \
                        >/dev/null 2>&1 || true
                else
                    python3 "$vnc_send_tool" --host 127.0.0.1 --port "$vnc_port" \
                        --keys "Space Space Space Space Space Space Space Space Space Space" \
                        --per-key-ms 120 --hold-ms 60 --post-delay 1.0 \
                        >/dev/null 2>&1 || true
                fi
                cdboot_prompt_handled=1
            fi
            if echo "$__ocr_text" | grep -qi "Windows Setup\|Select language\|Install now\|install Windows\|Copying\|Getting ready\|Expanding\|Disk.*Partition"; then
                echo "  WinPE boot detected via OCR"
                boot_detected=1
                break
            fi
            echo "  ... ${boot_wait}s (disk=$(numfmt --to=iec "$check_bytes" 2>/dev/null))"
        fi
        sleep 5
        boot_wait=$((boot_wait + 5))
    done

    if (( boot_detected == 0 )); then
        echo "  Boot failed (attempt $boot_attempt/$max_boot_attempts). Killing QEMU..."
        echo "quit" | nc -q1 localhost "$build_monitor" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$build_pid"
        continue  # retry
    fi

    echo ""
    printf "  %-8s  %-10s  %-12s  %-10s  %s\n" "ELAPSED" "DISK" "WRITTEN" "RATE" "PHASE"

    # Wait for WinPE to extract the image and reboot.
    # Detect reboot AFTER extraction (peak > 4GB) by either:
    #   (a) OCR shows firmware/boot text again after extraction, or
    #   (b) the disk has been idle for 60s after extraction.
    # At that point, stop QEMU and restart in Phase 2 with only the target
    # disk attached so Windows boots from its own ESP instead of the temporary
    # build ESP.
    local elapsed=$boot_wait
    local peak_disk_bytes=0
    local disk_idle_seconds=0
    local phase1_reboot_detected=0
    local phase1_restart_count=0
    local max_phase1_restarts=10
    local firmware_hang_seconds=0
    local boot_menu_handled=0
    local helper_esp_detached=0
    local target_esp_ready=0
    local last_disk_bytes
    last_disk_bytes=$(_disk_allocated_bytes "$build_disk")
    while kill -0 "$pid" 2>/dev/null; do
        local now_disk_bytes
        now_disk_bytes=$(_disk_allocated_bytes "$build_disk")

        if (( now_disk_bytes > peak_disk_bytes )); then
            peak_disk_bytes=$now_disk_bytes
        fi

        # Screenshot every 10s, progress line every 10s
        if (( elapsed % 10 == 0 && elapsed > 0 )); then
            local delta_bytes=$(( now_disk_bytes - last_disk_bytes ))
            local rate_bps=$(( delta_bytes / 10 ))
            local disk_h rate_h phase
            disk_h=$(numfmt --to=iec --suffix=B "$now_disk_bytes" 2>/dev/null || echo "?")
            rate_h=$(numfmt --to=iec --suffix=B/s "$rate_bps" 2>/dev/null || echo "?")

            if (( peak_disk_bytes > 4*1024*1024*1024 && rate_bps == 0 )); then
                disk_idle_seconds=$((disk_idle_seconds + 10))
            else
                disk_idle_seconds=0
            fi

            if (( peak_disk_bytes > 4*1024*1024*1024 && target_esp_ready == 0 )); then
                if _target_esp_has_boot_files "$build_disk"; then
                    echo "  Target ESP now contains Windows boot files."
                    target_esp_ready=1
                fi
            fi

            _capture_screen
            local screen_text="$__ocr_text"
            if [[ -n "$screen_text" ]]; then
                echo "  --- screen OCR ---"
                echo "$screen_text" | sed '/^$/d' | sed 's/^/  | /'
                echo "  ---"
            fi

            # Once WinPE is running from RAM, remove the temporary ESP so
            # Windows Setup cannot mistake it for the installed system disk's
            # ESP when it later runs bcdboot.
            if (( helper_esp_detached == 0 )); then
                if (( now_disk_bytes > 64*1024*1024 )) || \
                   echo "$screen_text" | grep -qi "Windows Setup\|Installing Windows\|Select language\|Install now\|Which type of installation\|Copying\|Expanding\|Getting ready"; then
                    if _detach_phase1_helper_esp; then
                        helper_esp_detached=1
                    fi
                fi
            fi

            # Determine phase from disk activity + OCR
            if (( elapsed < 60 )); then phase="uefi-boot"
            elif (( rate_bps > 1024*1024 )); then phase="image-extraction"
            elif (( rate_bps > 0 )); then phase="installing-windows"
            else phase="reboot-or-config"
            fi

            # Override phase with OCR-detected screen state
            if [[ -n "$screen_text" ]]; then
                if echo "$screen_text" | grep -qi "Press any key to boot"; then
                    phase="cdboot-prompt"
                elif echo "$screen_text" | grep -qi "failed to start\|invalid object\|0xc000\|installation has failed"; then
                    phase="ERROR-on-screen"
                elif echo "$screen_text" | grep -qi "Select language\|Windows Setup"; then
                    phase="winpe-setup"
                elif echo "$screen_text" | grep -qi "Install driver\|media driver"; then
                    phase="winpe-needs-driver"
                elif echo "$screen_text" | grep -qi "Which type of installation\|Install now"; then
                    phase="winpe-installing"
                elif echo "$screen_text" | grep -qi "Copying\|Expanding\|Installing features\|Getting ready"; then
                    phase="extracting-image"
                elif echo "$screen_text" | grep -qi "Shell>"; then
                    phase="uefi-shell"
                elif echo "$screen_text" | grep -qi "BdsDxe.*starting"; then
                    phase="firmware-boot"
                fi
            fi

            if echo "$screen_text" | grep -qi "Choose an operating system" && (( target_esp_ready == 0 )); then
                if (( boot_menu_handled == 0 )) && [[ -f "$vnc_send_tool" ]]; then
                    echo "  [*] Boot menu detected before target ESP is ready; selecting Windows Setup..."
                    python3 "$vnc_send_tool" --host 127.0.0.1 --port "$vnc_port" \
                        --keys "Down Enter" --per-key-ms 120 --hold-ms 60 --post-delay 1.0 \
                        >/dev/null 2>&1 || true
                    boot_menu_handled=1
                fi
            else
                boot_menu_handled=0
            fi

            if (( target_esp_ready == 0 && rate_bps == 0 )) && [[ "$phase" == "firmware-boot" ]]; then
                firmware_hang_seconds=$((firmware_hang_seconds + 10))
            else
                firmware_hang_seconds=0
            fi

            printf "  %-8s  %-10s  %-12s  %-10s  %s\n" \
                "$(printf '%dm%02ds' $((elapsed/60)) $((elapsed%60)))" \
                "$disk_h" "" "$rate_h" "$phase"

            # Bail on detected errors
            if [[ "$phase" == "ERROR-on-screen" ]]; then
                echo ""
                echo "  [!] ERROR detected on screen. OCR text:"
                echo "$screen_text" | grep -i "error\|fail\|invalid\|0xc000\|status" | sed 's/^/  [!]   /'
                echo ""
            fi

            if (( target_esp_ready == 1 )); then
                if [[ "$phase" == "firmware-boot" || "$phase" == "uefi-shell" || "$phase" == "cdboot-prompt" ]]; then
                    echo ""
                    echo "  [*] First reboot detected via firmware screen after image extraction."
                    echo "  [*] Stopping QEMU to hand off to disk-only Phase 2..."
                    echo "quit" | nc -q1 localhost "$build_monitor" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
                    sleep 2
                    rm -f "$build_pid"
                    phase1_reboot_detected=1
                    break
                fi

                if (( disk_idle_seconds >= 60 )); then
                    echo ""
                    echo "  [*] First reboot inferred from post-extraction disk idle (${disk_idle_seconds}s)."
                    echo "  [*] Stopping QEMU to hand off to disk-only Phase 2..."
                    echo "quit" | nc -q1 localhost "$build_monitor" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
                    sleep 2
                    rm -f "$build_pid"
                    phase1_reboot_detected=1
                    break
                fi
            fi

            if (( target_esp_ready == 0 && firmware_hang_seconds >= 60 )); then
                phase1_restart_count=$((phase1_restart_count + 1))
                if (( phase1_restart_count > max_phase1_restarts )); then
                    echo ""
                    echo "  Phase 1 failed: build ESP boot manager remained hung after ${max_phase1_restarts} relaunch attempts."
                    echo "  Artifacts preserved for inspection:"
                    echo "    $build_disk"
                    echo "    $build_vars"
                    exit 1
                fi

                echo ""
                echo "  [!] Phase 1 stall at temporary Windows Boot Manager; relaunching attempt ${phase1_restart_count}/${max_phase1_restarts} with preserved NVRAM..."
                echo "quit" | nc -q1 localhost "$build_monitor" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
                sleep 3
                kill -9 "$pid" 2>/dev/null || true
                rm -f "$build_pid"

                if ! _start_phase1_qemu; then
                    exit 1
                fi

                last_disk_bytes=$(_disk_allocated_bytes "$build_disk")
                disk_idle_seconds=0
                firmware_hang_seconds=0
                continue
            fi

            last_disk_bytes=$now_disk_bytes
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    if (( phase1_reboot_detected == 0 )); then
        echo "  Phase 1 failed after WinPE boot; reboot boundary was not observed."
        echo "  Artifacts preserved for inspection:"
        echo "    $build_disk"
        echo "    $build_vars"
        exit 1
    fi

    boot_ok=1
    echo "  Phase 1 complete (${elapsed}s). Image extracted to disk."
    break  # exit retry loop
    done   # end boot retry loop

    if (( boot_ok == 0 )); then
        echo ""
        echo "  FATAL: WinPE failed to boot after $max_boot_attempts attempts."
        echo "  Check BOOT.md for debugging guidance."
        exit 1
    fi

    # ── PHASE 2: Boot from installed disk, complete specialize/OOBE ─────
    #
    # The temporary ESP/installer media are only for WinPE. Once the image has
    # been applied and Windows reboots, continue with only the target disk
    # attached so firmware sees a single Windows ESP instead of the build-time
    # boot media.

    echo ""
    echo "Phase 2: Continuing install from target disk..."
    echo ""

    rm -f "$build_log" "$build_pid"

    windows_qemu_aarch64 \
        -nodefaults \
        -cpu host \
        -smp "${WIN_CPUS},sockets=1,dies=1,cores=${WIN_CPUS},threads=1" \
        -m "$WIN_RAM" \
        -machine "type=virt,secure=off,gic-version=max,accel=kvm" \
        -enable-kvm \
        -smbios "type=1,serial=${WIN_SMBIOS_SERIAL}" \
        -display "vnc=${build_vnc},websocket=${build_vnc_ws}" \
        -device ramfb \
        -monitor "telnet:localhost:${build_monitor},server,nowait,nodelay" \
        -daemonize \
        -D "$build_log" \
        -pidfile "$build_pid" \
        -name "base-build-windows" \
        -serial pty \
        -device "qemu-xhci" \
        -device usb-kbd \
        -device usb-tablet \
        -netdev "tap,id=hostnet0,ifname=${build_tap},script=no,downscript=no" \
        -device "virtio-net-pci,netdev=hostnet0,mac=${build_mac}" \
        -drive "file=${virtio_iso},id=virtio0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
        -device "usb-storage,drive=virtio0,removable=on" \
        -drive "file=${build_disk},id=data0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none" \
        -device "nvme,serial=builddisk0,drive=data0,bootindex=1" \
        -drive "file=${build_rom},if=pflash,unit=0,format=raw,readonly=on" \
        -drive "file=${build_vars},if=pflash,unit=1,format=raw" \
        -object "rng-random,id=rng0,filename=/dev/urandom" \
        -device "virtio-rng-pci,rng=rng0" \
        -rtc base=localtime

    local phase2_pid_wait=0
    while [[ ! -f "$build_pid" ]] && (( phase2_pid_wait < 10 )); do
        sleep 1
        phase2_pid_wait=$((phase2_pid_wait + 1))
    done

    if [[ ! -f "$build_pid" ]]; then
        echo "Failed to start QEMU for phase 2 (no PID file after ${phase2_pid_wait}s). Check $build_log"
        exit 1
    fi

    pid=$(cat "$build_pid")
    echo "  QEMU started (PID: $pid)"

    echo ""
    echo "Watch progress:"
    echo "  Screenshots:    ls $screen_dir/      (every 10s)"
    echo "  VNC viewer:     vncviewer localhost${build_vnc}"
    echo "  Manual control: telnet localhost ${build_monitor}"
    echo "  Force stop:     echo quit | nc -q1 localhost ${build_monitor}"
    echo ""
    echo "Waiting for install to complete and VM to shut down..."
    echo "  Soft cap: ${build_timeout}s (advisory only — VM will not be killed)"
    echo "  The VM shuts itself down when FirstLogonCommands finish."
    echo ""
    printf "  %-8s  %-10s  %-12s  %-10s  %s\n" "ELAPSED" "DISK" "WRITTEN" "RATE" "PHASE"

    # Wait for VM to shut down, with stall-detect + restart-in-place.
    # On ARM64 QEMU, bootmgfw silent-exits ~50% of reboots. When Windows
    # Setup reboots mid-install (specialize/OOBE phases), the VM can get
    # stuck at the firmware screen forever. Detect: disk mtime unchanged
    # AND screen unchanged for > stall_limit seconds → kill QEMU and
    # restart with same disk + NVRAM (NVRAM now has Windows-written boot
    # entries from bcdboot, so the restart should pick them up).
    local soft_timeout_warned=0
    local stall_limit=120
    local bootmgr_hang_limit=30
    local repair_grace_limit=180
    local max_restarts=80
    local restart_count=0
    local vm_shutdown_clean=0
    local install_error_dialog_last_ack=-9999
    local boot_option_enter_last_sent=-9999
    local last_disk_mtime last_disk_change last_screen_hash last_screen_change
    last_disk_bytes=$(_disk_allocated_bytes "$build_disk")
    local start_disk_bytes=$last_disk_bytes

    while (( restart_count <= max_restarts )); do
    local restart_requested=0
    last_disk_mtime=$(stat -c %Y "$build_disk" 2>/dev/null || echo 0)
    last_disk_change=$elapsed
    last_screen_hash=""
    last_screen_change=$elapsed

    while kill -0 "$pid" 2>/dev/null; do
        local now_disk_mtime now_disk_bytes
        now_disk_mtime=$(stat -c %Y "$build_disk" 2>/dev/null || echo 0)
        now_disk_bytes=$(_disk_allocated_bytes "$build_disk")

        if [[ "$now_disk_mtime" != "$last_disk_mtime" ]]; then
            last_disk_mtime="$now_disk_mtime"
            last_disk_change=$elapsed
        fi
        local since_disk_change=$(( elapsed - last_disk_change ))
        local since_screen_change=$(( elapsed - last_screen_change ))

        if (( elapsed >= build_timeout && soft_timeout_warned == 0 )); then
            echo ""
            echo "  [!] Build has been running ${elapsed}s (>${build_timeout}s soft cap)."
            soft_timeout_warned=1
        fi

        if (( elapsed % 10 == 0 && elapsed > 0 )); then
            _capture_screen

            local now_screen_hash=""
            if [[ -f "${screen_dir}/latest.png" ]]; then
                now_screen_hash=$(md5sum "${screen_dir}/latest.png" 2>/dev/null | cut -d' ' -f1)
            fi
            if [[ -n "$now_screen_hash" && "$now_screen_hash" != "$last_screen_hash" ]]; then
                last_screen_hash="$now_screen_hash"
                last_screen_change=$elapsed
                since_screen_change=0
            fi

            local phase2_screen_text="$__ocr_text"
            local phase2_dialog_text=""
            if [[ -f "${screen_dir}/latest.png" ]]; then
                phase2_dialog_text=$(_dialog_crop_ocr "${screen_dir}/latest.png")
            fi
            local combined_screen_text="$phase2_screen_text"$'\n'"$phase2_dialog_text"
            local repair_screen_detected=0
            if echo "$combined_screen_text" | grep -qi "Preparing Automatic Repair\|Diagnosing your PC\|Automatic Repair"; then
                repair_screen_detected=1
            fi
            if echo "$combined_screen_text" | grep -qi "Windows could not complete\|restart the instal"; then
                if (( elapsed - install_error_dialog_last_ack >= 10 )); then
                    echo ""
                    echo "  [*] Setup error dialog detected; clicking OK and allowing reboot..."
                    if [[ -f "$vnc_click_tool" ]]; then
                        python3 "$vnc_click_tool" --host 127.0.0.1 --port "$vnc_port" \
                            --x 545 --y 378 >/dev/null 2>&1 || true
                    elif [[ -f "$vnc_send_tool" ]]; then
                        python3 "$vnc_send_tool" --host 127.0.0.1 --port "$vnc_port" \
                            --keys "Enter Space" --per-key-ms 120 --hold-ms 60 --post-delay 1.0 \
                            >/dev/null 2>&1 || true
                    fi
                    install_error_dialog_last_ack=$elapsed
                fi
            fi
            if (( repair_screen_detected == 0 )) &&
               echo "$combined_screen_text" | grep -qi "Start boot option" &&
               (( elapsed - boot_option_enter_last_sent >= 20 )) &&
               [[ -f "$vnc_send_tool" ]]; then
                echo ""
                echo "  [*] Windows Boot Manager screen detected; sending key sequence to start the selected boot option..."
                python3 "$vnc_send_tool" --host 127.0.0.1 --port "$vnc_port" \
                    --keys "Enter Enter Space Enter" --per-key-ms 200 --hold-ms 80 --post-delay 1.0 \
                    >/dev/null 2>&1 || true
                if [[ -f "$vnc_spam_tool" ]]; then
                    python3 "$vnc_spam_tool" --host 127.0.0.1 --port "$vnc_port" \
                        --key Enter --duration 4 --rate 4 --hold-ms 80 \
                        >/dev/null 2>&1 || true
                fi
                boot_option_enter_last_sent=$elapsed
            fi

            local delta_bytes=$(( now_disk_bytes - last_disk_bytes ))
            local written_bytes=$(( now_disk_bytes - start_disk_bytes ))
            local rate_bps=$(( delta_bytes / 10 ))
            local disk_h written_h rate_h phase effective_stall_limit
            disk_h=$(numfmt --to=iec --suffix=B "$now_disk_bytes" 2>/dev/null || echo "?")
            written_h=$(numfmt --to=iec --suffix=B "$written_bytes" 2>/dev/null || echo "?")
            rate_h=$(numfmt --to=iec --suffix=B/s "$rate_bps" 2>/dev/null || echo "?")
            effective_stall_limit=$stall_limit

            if (( repair_screen_detected == 1 )); then
                effective_stall_limit=$repair_grace_limit
                phase="automatic-repair (d=${since_disk_change}s s=${since_screen_change}s)"
            elif echo "$combined_screen_text" | grep -qi "Start boot option" &&
               (( since_disk_change >= bootmgr_hang_limit && since_screen_change >= bootmgr_hang_limit )); then
                phase="bootmgr-hang (disk=${since_disk_change}s screen=${since_screen_change}s)"
            elif (( since_disk_change >= effective_stall_limit && since_screen_change >= effective_stall_limit )); then
                phase="STALLED (disk=${since_disk_change}s screen=${since_screen_change}s)"
            elif (( rate_bps > 1024*1024 )); then
                phase="installing-windows"
            elif (( rate_bps > 0 )); then
                phase="configuring"
            else
                phase="reboot-or-idle (d=${since_disk_change}s s=${since_screen_change}s)"
            fi

            printf "  %-8s  %-10s  %-12s  %-10s  %s\n" \
                "$(printf '%dm%02ds' $((elapsed/60)) $((elapsed%60)))" \
                "$disk_h" "$written_h" "$rate_h" "$phase"

            last_disk_bytes=$now_disk_bytes

            if (( repair_screen_detected == 0 )) &&
               echo "$combined_screen_text" | grep -qi "Start boot option" &&
               (( since_disk_change >= bootmgr_hang_limit && since_screen_change >= bootmgr_hang_limit )); then
                echo ""
                echo "  [!] Windows Boot Manager hang detected — killing QEMU and restarting (attempt $((restart_count+1))/${max_restarts})"
                restart_requested=1
                echo "quit" | nc -q1 localhost "$build_monitor" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
                sleep 3
                kill -9 "$pid" 2>/dev/null || true
                rm -f "$build_pid"
                break
            fi

            if (( since_disk_change >= effective_stall_limit && since_screen_change >= effective_stall_limit )); then
                echo ""
                echo "  [!] STALL detected — killing QEMU and restarting (attempt $((restart_count+1))/${max_restarts})"
                restart_requested=1
                echo "quit" | nc -q1 localhost "$build_monitor" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
                sleep 3
                kill -9 "$pid" 2>/dev/null || true
                rm -f "$build_pid"
                break
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if (( restart_requested == 0 )); then
        if ! kill -0 "$pid" 2>/dev/null && [[ ! -f "$build_pid" ]] && (( since_disk_change < stall_limit || since_screen_change < stall_limit )); then
            vm_shutdown_clean=1
            break
        fi
        if kill -0 "$pid" 2>/dev/null; then
            # Fell out of inner loop without stall (shouldn't happen, but be safe)
            vm_shutdown_clean=1
            break
        fi
        if ! [[ -f "$build_pid" ]]; then
            # QEMU exited cleanly (Windows shutdown)
            if (( since_disk_change < stall_limit )); then
                vm_shutdown_clean=1
                break
            fi
        fi
    fi

    # Stall detected. Restart QEMU with same disks + NVRAM (no wipe).
    restart_count=$(( restart_count + 1 ))
    echo ""
    echo "  Restart #$restart_count: relaunching QEMU with preserved disk + NVRAM..."

    windows_qemu_aarch64 \
        -nodefaults \
        -cpu host \
        -smp "${WIN_CPUS},sockets=1,dies=1,cores=${WIN_CPUS},threads=1" \
        -m "$WIN_RAM" \
        -machine "type=virt,secure=off,gic-version=max,accel=kvm" \
        -enable-kvm \
        -smbios "type=1,serial=${WIN_SMBIOS_SERIAL}" \
        -display "vnc=${build_vnc},websocket=${build_vnc_ws}" \
        -device ramfb \
        -monitor "telnet:localhost:${build_monitor},server,nowait,nodelay" \
        -daemonize \
        -D "$build_log" \
        -pidfile "$build_pid" \
        -name "base-build-windows" \
        -serial pty \
        -device "qemu-xhci" \
        -device usb-kbd \
        -device usb-tablet \
        -netdev "tap,id=hostnet0,ifname=${build_tap},script=no,downscript=no" \
        -device "virtio-net-pci,netdev=hostnet0,mac=${build_mac}" \
        -drive "file=${virtio_iso},id=virtio0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
        -device "usb-storage,drive=virtio0,removable=on" \
        -drive "file=${build_disk},id=data0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none" \
        -device "nvme,serial=builddisk0,drive=data0,bootindex=1" \
        -drive "file=${build_rom},if=pflash,unit=0,format=raw,readonly=on" \
        -drive "file=${build_vars},if=pflash,unit=1,format=raw" \
        -object "rng-random,id=rng0,filename=/dev/urandom" \
        -device "virtio-rng-pci,rng=rng0" \
        -rtc base=localtime

    local rs_wait=0
    while [[ ! -f "$build_pid" ]] && (( rs_wait < 10 )); do
        sleep 1
        rs_wait=$((rs_wait + 1))
    done
    if [[ ! -f "$build_pid" ]]; then
        echo "  Failed to relaunch QEMU (no PID file). Check $build_log"
        break
    fi
    pid=$(cat "$build_pid")
    echo "  QEMU relaunched (PID: $pid)"
    done  # end restart-on-stall outer loop

    if (( vm_shutdown_clean == 0 )); then
        echo ""
        echo "  FATAL: VM failed to complete install after $max_restarts restart attempts."
        echo "  Artifacts preserved for inspection:"
        echo "    $build_disk"
        echo "    $build_vars"
        exit 1
    fi

    echo ""
    echo "  VM shut down after $((elapsed / 60))m $((elapsed % 60))s"

    rm -f "$build_pid"

    echo ""
    echo "Converting raw disk to compressed qcow2..."
    qemu-img convert -f raw -O qcow2 -c "$build_disk" "$BASE_WINDOWS_DISK"

    echo "Copying UEFI files to base image directory..."
    cp "$build_vars" "$BASE_WINDOWS_VARS"
    cp "$build_rom" "$BASE_WINDOWS_ROM"

    echo "Cleaning up build files..."
    rm -f "$build_disk" "$build_vars" "$build_rom" "$build_esp" "$build_usb" "$build_log"

    # Clean up TAP (will recreate for verification)
    if ip link show "$build_tap" &>/dev/null; then
        ip link set "$build_tap" down 2>/dev/null || true
        ip link delete "$build_tap" 2>/dev/null || true
    fi

    # Verify base image by booting and probing SSH
    echo ""
    echo "Verifying base image (quick boot + SSH probe)..."
    local verify_ok=0
    # verify_ip is populated from the DHCP lease after the VM boots;
    # the base image is now DHCP, so it changes per build and per run.
    local verify_ip=""
    local verify_user="testuser"
    local verify_name="base-verify"
    local verify_vnc=":10"
    local verify_monitor="7200"
    local verify_vnc_port=5910
    local verify_screen_dir="${STORAGE_DIR}/winverify-latest"
    local verify_known_hosts="/tmp/winvm-${verify_name}.known_hosts"
    local verify_ssh_key=""
    local -a verify_ssh_cmd=(ssh)
    local key_type
    local key_user="${SUDO_USER:-${USER:-root}}"
    rm -rf "$verify_screen_dir"
    mkdir -p "$verify_screen_dir"
    rm -f "$verify_known_hosts"
    for key_type in id_ed25519 id_rsa; do
        if [[ -f "/home/${key_user}/.ssh/${key_type}" ]]; then
            verify_ssh_key="/home/${key_user}/.ssh/${key_type}"
            break
        fi
    done
    if [[ -n "$verify_ssh_key" ]]; then
        echo "  Using SSH identity: $verify_ssh_key"
        verify_ssh_cmd+=(-i "$verify_ssh_key" -o IdentitiesOnly=yes)
    fi
    verify_ssh_cmd+=(
        -o ConnectTimeout=3
        -o BatchMode=yes
        -o UserKnownHostsFile="$verify_known_hosts"
        -o StrictHostKeyChecking=accept-new
    )

    _verify_capture_screen() {
        __verify_ocr_text=""
        if [[ ! -f "$vnc_tool" ]]; then return; fi
        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        local ppm="${verify_screen_dir}/${ts}.ppm"
        local png="${verify_screen_dir}/${ts}.png"
        python3 "$vnc_tool" --host 127.0.0.1 --port "$verify_vnc_port" \
            --screenshot "$ppm" 2>/dev/null || return 0
        python3 -c "from PIL import Image; Image.open('$ppm').save('$png')" 2>/dev/null || return 0
        rm -f "$ppm"
        ln -sf "$png" "${verify_screen_dir}/latest.png"
        if command -v tesseract >/dev/null 2>&1 && [[ -f "$png" ]]; then
            __verify_ocr_text=$(tesseract "$png" stdout 2>/dev/null || true)
        fi
    }

    # Create overlay from new base image
    if windows_overlay_create "$verify_name" >/dev/null 2>&1; then
        # Recreate network for verification VM
        ensure_tap "$build_tap" "$BRIDGE_NAME" 2>/dev/null

        # Start VM quietly (using VNC :10 to avoid conflict)
        if windows_vm_start "$verify_name" "" "$build_tap" "$verify_vnc" "$verify_monitor" >/dev/null 2>&1; then
            echo "  Waiting for DHCP lease + SSH as ${verify_user}..."

            # The verification overlay can land in the same Windows Boot
            # Manager hang as the installer. Keep the overlay + NVRAM and
            # retry that boot path instead of giving up on the first miss.
            local verify_restart_count=0
            local max_verify_restarts=80
            local verify_bootmgr_hang_limit=30
            local verify_attempt_timeout=600
            local verify_elapsed=0
            local verify_last_screen_hash=""
            local verify_last_screen_change=0
            local verify_boot_option_enter_last_sent=-9999

            while (( verify_restart_count <= max_verify_restarts && verify_ok == 0 )); do
                local verify_restart_requested=0

                while (( verify_elapsed < verify_attempt_timeout )); do
                    if [[ -z "$verify_ip" ]]; then
                        verify_ip=$(windows_vm_lease "$verify_name" 2 2>/dev/null || true)
                        if [[ -n "$verify_ip" ]]; then
                            echo "  DHCP lease acquired: ${verify_ip}"
                        fi
                    fi

                    if [[ -n "$verify_ip" ]] && \
                       "${verify_ssh_cmd[@]}" "${verify_user}@${verify_ip}" "echo ready" 2>/dev/null | grep -q ready; then
                        echo "  SSH verification: SUCCESS (${verify_ip})"
                        verify_ok=1
                        break
                    fi

                    if (( verify_elapsed % 10 == 0 )); then
                        _verify_capture_screen
                        local verify_screen_hash=""
                        if [[ -f "${verify_screen_dir}/latest.png" ]]; then
                            verify_screen_hash=$(md5sum "${verify_screen_dir}/latest.png" 2>/dev/null | cut -d' ' -f1)
                        fi
                        if [[ -n "$verify_screen_hash" && "$verify_screen_hash" != "$verify_last_screen_hash" ]]; then
                            verify_last_screen_hash="$verify_screen_hash"
                            verify_last_screen_change=$verify_elapsed
                        fi

                        local verify_since_screen_change=$(( verify_elapsed - verify_last_screen_change ))
                        if ! echo "$__verify_ocr_text" | grep -qi "Preparing Automatic Repair\|Diagnosing your PC\|Automatic Repair" &&
                           echo "$__verify_ocr_text" | grep -qi "Start boot option" &&
                           (( verify_elapsed - verify_boot_option_enter_last_sent >= 20 )) &&
                           [[ -f "$vnc_send_tool" ]]; then
                            python3 "$vnc_send_tool" --host 127.0.0.1 --port "$verify_vnc_port" \
                                --keys "Enter Enter Space Enter" --per-key-ms 200 --hold-ms 80 --post-delay 1.0 \
                                >/dev/null 2>&1 || true
                            if [[ -f "$vnc_spam_tool" ]]; then
                                python3 "$vnc_spam_tool" --host 127.0.0.1 --port "$verify_vnc_port" \
                                    --key Enter --duration 4 --rate 4 --hold-ms 80 \
                                    >/dev/null 2>&1 || true
                            fi
                            verify_boot_option_enter_last_sent=$verify_elapsed
                        fi
                        if echo "$__verify_ocr_text" | grep -qi "Start boot option" &&
                           (( verify_since_screen_change >= verify_bootmgr_hang_limit )); then
                            echo "  Verification hit Windows Boot Manager hang; restarting verify VM (attempt $((verify_restart_count+1))/${max_verify_restarts})"
                            verify_restart_requested=1
                            windows_vm_stop "$verify_name" "$verify_monitor" >/dev/null 2>&1 || true
                            break
                        fi
                    fi

                    sleep 5
                    verify_elapsed=$((verify_elapsed + 5))
                done

                if (( verify_ok == 1 )); then
                    break
                fi

                if (( verify_restart_requested == 0 )); then
                    break
                fi

                verify_restart_count=$((verify_restart_count + 1))
                if (( verify_restart_count > max_verify_restarts )); then
                    break
                fi

                if ! windows_vm_start "$verify_name" "" "$build_tap" "$verify_vnc" "$verify_monitor" >/dev/null 2>&1; then
                    echo "  WARNING: Could not restart verification VM"
                    break
                fi

                # Fresh boot — re-query DHCP lease; IP may have changed.
                verify_ip=""
                verify_elapsed=0
                verify_last_screen_hash=""
                verify_last_screen_change=0
            done

            if [[ $verify_ok -eq 0 ]]; then
                echo "  SSH verification: FAILED"
                echo "  WARNING: Base image may be incomplete. Check C:\\Windows\\Temp\\firstlogon.log"
            fi

            # Shut down verification VM
            windows_vm_stop "$verify_name" "$verify_monitor" >/dev/null 2>&1 || true
        else
            echo "  WARNING: Could not start verification VM"
        fi

        # Clean up verification overlay
        windows_vm_destroy "$verify_name" "$build_tap" "$verify_monitor" >/dev/null 2>&1 || true
        rm -f "$verify_known_hosts"
    else
        echo "  WARNING: Could not create verification overlay"
    fi

    # Final TAP cleanup
    if ip link show "$build_tap" &>/dev/null; then
        ip link set "$build_tap" down 2>/dev/null || true
        ip link delete "$build_tap" 2>/dev/null || true
    fi

    echo ""
    echo "======================================================="
    if [[ $verify_ok -eq 1 ]]; then
        echo "Base image VERIFIED and ready at $BASE_IMAGE_DIR"
    else
        echo "Base image ready at $BASE_IMAGE_DIR (SSH verification failed)"
        echo "  Check firstlogon.log on the VM for errors"
    fi
    echo ""
    local base_size
    base_size=$(du -h "$BASE_WINDOWS_DISK" 2>/dev/null | cut -f1)
    echo "  Disk:  $BASE_WINDOWS_DISK ($base_size)"
    echo "  Vars:  $BASE_WINDOWS_VARS"
    echo "  ROM:   $BASE_WINDOWS_ROM"
    echo ""
    echo "Create VMs with:"
    echo "  sudo ./winvm.sh start <name>"
}

# ─── Main ──────────────────────────────────────────────────────────────

main() {
    local command=""

    # Handle --help / -h at any position
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
            show_usage
            exit 0
        fi
    done

    if [[ $# -lt 1 ]]; then
        show_usage
        exit 1
    fi

    command="$1"
    shift

    case "$command" in
        start)
            [[ $# -lt 1 ]] && { echo "Error: name required"; show_usage; exit 1; }
            cmd_start "$@"
            ;;
        stop)
            [[ $# -lt 1 ]] && { echo "Error: name required"; show_usage; exit 1; }
            cmd_stop "$1"
            ;;
        destroy)
            [[ $# -lt 1 ]] && { echo "Error: name required"; show_usage; exit 1; }
            cmd_destroy "$1"
            ;;
        ssh)
            [[ $# -lt 1 ]] && { echo "Error: name required"; show_usage; exit 1; }
            cmd_ssh "$@"
            ;;
        exec)
            [[ $# -lt 2 ]] && { echo "Error: name and command required"; show_usage; exit 1; }
            cmd_exec "$@"
            ;;
        status)
            [[ $# -lt 1 ]] && { echo "Error: name required"; show_usage; exit 1; }
            cmd_status "$@"
            ;;
        ip)
            [[ $# -lt 1 ]] && { echo "Error: name required"; show_usage; exit 1; }
            cmd_ip "$1"
            ;;
        list)
            cmd_list
            ;;
        image)
            [[ $# -lt 1 ]] && { echo "Error: image subcommand required (build|status|destroy)"; exit 1; }
            local subcmd="$1"
            shift
            case "$subcmd" in
                build)   cmd_image_build ;;
                status)  cmd_image_status ;;
                destroy) cmd_image_destroy ;;
                *)       echo "Unknown image subcommand: $subcmd"; exit 1 ;;
            esac
            ;;
        *)
            echo "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
