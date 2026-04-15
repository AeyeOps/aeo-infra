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
WIN_DEFAULT_IP="${VM_SUBNET}.200"

# ─── Usage ─────────────────────────────────────────────────────────────

show_usage() {
    cat << 'EOF'
Usage: ./winvm.sh <command> [args]

Instance commands:
  start <name> [--ip IP]    Start a new Windows VM (auto-builds base image if needed)
  stop <name>               Graceful shutdown
  destroy <name>            Full teardown (stop + delete overlay)
  ssh <name>                Connect via SSH
  exec <name> <cmd>         Run command on VM via SSH
  status <name>             Check VM state
  list                      List running Windows VMs

Base image commands:
  image build               Build base image (interactive, one-time)
  image status              Check if base image exists
  image destroy             Remove base image

Options:
  --ip IP       Override default IP (default: 192.168.50.200)
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
    local ip="$WIN_DEFAULT_IP"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip) ip="$2"; shift 2 ;;
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

    # Ensure network
    local tap="tap-win-${name}"
    local upstream
    upstream=$(detect_upstream_interface)
    ensure_bridge "$BRIDGE_NAME" "$HOST_IP"
    ensure_tap "$tap" "$BRIDGE_NAME"
    ensure_ip_forwarding
    ensure_nat_masquerade "$upstream"
    ensure_forward_rules "$BRIDGE_NAME" "$upstream"
    echo ""

    # Start VM
    windows_vm_start "$name" "$ip" "$tap"
    echo ""

    # Wait for SSH
    windows_vm_wait_ssh "$ip"

    echo ""
    echo "======================================================="
    echo "Windows VM 'winvm-${name}' ready"
    echo ""
    echo "  SSH:  ssh ${WIN_USER}@${ip}"
    echo "  VNC:  localhost:8 (port 5908)"
    echo ""
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
    local ip="${2:-$WIN_DEFAULT_IP}"

    exec ssh -o StrictHostKeyChecking=accept-new "${WIN_USER}@${ip}"
}

cmd_exec() {
    local name="$1"
    shift
    local ip="$WIN_DEFAULT_IP"

    windows_vm_exec "$ip" "$*"
}

cmd_status() {
    local name="$1"
    local ip="${2:-$WIN_DEFAULT_IP}"

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
    local build_pid="/run/shm/base-build-windows.pid"
    local build_log="/run/shm/base-build-windows.log"
    local build_tap="tap-win-build"
    local build_vnc=":9"
    local build_vnc_ws="5709"
    local build_monitor="7199"
    local build_mac="02:aa:bb:cc:dd:ee"
    local build_timeout=10800  # 3h soft cap; we warn but do not kill
    local stall_threshold=600  # warn if build disk unchanged for 10 min

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

    # Create build disk and seed it with startup.nsh + Autounattend.xml.
    # A small EFI System Partition at the start of the disk lets the UEFI
    # Shell find startup.nsh after cdboot.efi's "Press any key" times out.
    # Windows Setup's WillWipeDisk=true wipes this partition later.
    echo "Creating 64G build disk..."
    qemu-img create -f raw "$build_disk" 64G
    if ! seed_build_disk "$build_disk"; then
        echo "Failed to seed build disk. Cannot proceed." >&2
        exit 1
    fi

    # Create UEFI files
    echo "Creating UEFI firmware files..."
    local uefi_source="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
    truncate -s 64M "$build_rom"
    dd if="$uefi_source" of="$build_rom" conv=notrunc 2>/dev/null
    truncate -s 64M "$build_vars"

    # Ensure network
    local upstream
    upstream=$(detect_upstream_interface)
    ensure_bridge "$BRIDGE_NAME" "$HOST_IP"
    ensure_tap "$build_tap" "$BRIDGE_NAME"
    ensure_ip_forwarding
    ensure_nat_masquerade "$upstream"
    ensure_forward_rules "$BRIDGE_NAME" "$upstream"

    # Sparse-aware allocated-bytes helper (returns 0 on error)
    _disk_allocated_bytes() {
        du --block-size=1 "$1" 2>/dev/null | cut -f1
    }

    local screen_ppm="/tmp/winbuild-latest.ppm"

    # ── PHASE 1: Boot from ISO, extract Windows image ──────────────────
    #
    # The build disk's seeded ESP is bootindex=0 and contains UEFI Shell
    # as \EFI\BOOT\BOOTAA64.EFI. UEFI launches Shell → auto-runs
    # startup.nsh → launches bootmgfw from the ISO's UDF filesystem →
    # Windows Setup starts. This bypasses cdboot.efi entirely (cdboot
    # hangs on ARM64: no timeout, VNC/sendkey can't dismiss it).
    #
    # WinPE discovers Autounattend.xml on the ESP, partitions the disk,
    # extracts the WIM image (~8GB), sets up the EFI boot manager, and
    # reboots. We detect the reboot and STOP QEMU to prevent reinstall.

    echo ""
    echo "Phase 1: Extracting Windows image from ISO..."
    echo ""

    qemu-system-aarch64 \
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
        -object "iothread,id=io0" \
        -device "virtio-scsi-pci,id=scsi0,bus=pcie.0,iothread=io0" \
        -drive "file=${build_disk},id=data0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none" \
        -device "scsi-hd,drive=data0,bus=scsi0.0,bootindex=0" \
        -drive "file=${iso_file},id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
        -device "scsi-cd,drive=cdrom0,bus=scsi0.0" \
        -drive "file=${virtio_iso},id=virtio0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
        -device "scsi-cd,drive=virtio0,bus=scsi0.0" \
        -drive "file=${build_rom},if=pflash,unit=0,format=raw,readonly=on" \
        -drive "file=${build_vars},if=pflash,unit=1,format=raw" \
        -object "rng-random,id=rng0,filename=/dev/urandom" \
        -device "virtio-rng-pci,rng=rng0" \
        -rtc base=localtime

    sleep 1

    if [[ ! -f "$build_pid" ]]; then
        echo "Failed to start QEMU. Check $build_log"
        exit 1
    fi

    local pid
    pid=$(cat "$build_pid")
    echo "  QEMU started (PID: $pid)"
    echo "  Boot path: disk ESP → UEFI Shell → startup.nsh → ISO bootmgfw"
    echo ""
    printf "  %-8s  %-10s  %-12s  %-10s  %s\n" "ELAPSED" "DISK" "WRITTEN" "RATE" "PHASE"

    # Wait for WinPE to extract the image and reboot.
    # Detect: disk peaked above 4GB then dropped below 2GB (sparse reclaim on reboot).
    local elapsed=0
    local peak_disk_bytes=0
    local last_disk_bytes
    last_disk_bytes=$(_disk_allocated_bytes "$build_disk")
    while kill -0 "$pid" 2>/dev/null; do
        local now_disk_bytes
        now_disk_bytes=$(_disk_allocated_bytes "$build_disk")

        if (( now_disk_bytes > peak_disk_bytes )); then
            peak_disk_bytes=$now_disk_bytes
        fi

        # Detect first reboot: peak passed 4GB, now dropped below 2GB
        if (( elapsed > 120 && peak_disk_bytes > 4*1024*1024*1024 && now_disk_bytes < 2*1024*1024*1024 )); then
            echo ""
            echo "  [*] First reboot detected (peak=${peak_disk_bytes}, now=${now_disk_bytes})"
            echo "  [*] Stopping QEMU to remove ISO before next boot..."
            echo "quit" | nc -q1 localhost "$build_monitor" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
            sleep 2
            rm -f "$build_pid"
            break
        fi

        # Progress line every 30s
        if (( elapsed % 30 == 0 && elapsed > 0 )); then
            local delta_bytes=$(( now_disk_bytes - last_disk_bytes ))
            local rate_bps=$(( delta_bytes / 30 ))
            local disk_h rate_h phase
            disk_h=$(numfmt --to=iec --suffix=B "$now_disk_bytes" 2>/dev/null || echo "?")
            rate_h=$(numfmt --to=iec --suffix=B/s "$rate_bps" 2>/dev/null || echo "?")

            if (( elapsed < 60 )); then phase="uefi-boot"
            elif (( rate_bps > 1024*1024 )); then phase="image-extraction"
            elif (( rate_bps > 0 )); then phase="installing-windows"
            else phase="reboot-or-config"
            fi

            printf "  %-8s  %-10s  %-12s  %-10s  %s\n" \
                "$(printf '%dm%02ds' $((elapsed/60)) $((elapsed%60)))" \
                "$disk_h" "" "$rate_h" "$phase"

            last_disk_bytes=$now_disk_bytes
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    echo "  Phase 1 complete (${elapsed}s). Image extracted to disk."

    # ── PHASE 2: Boot from disk, complete install ──────────────────────
    #
    # Restart QEMU WITHOUT the Windows ISO. UEFI boots from the disk's
    # EFI partition (WinPE set up the boot manager in phase 1). Windows
    # continues through specialize → OOBE → FirstLogonCommands → shutdown.
    # The VirtIO ISO stays attached for driver discovery during specialize.

    echo ""
    echo "Phase 2: Continuing install from disk (no ISO)..."
    echo ""

    rm -f "$build_log"

    qemu-system-aarch64 \
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
        -object "iothread,id=io0" \
        -drive "file=${build_disk},id=data0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none" \
        -device "virtio-scsi-pci,id=scsi0,bus=pcie.0,iothread=io0" \
        -device "scsi-hd,drive=data0,bus=scsi0.0,bootindex=0" \
        -drive "file=${build_rom},if=pflash,unit=0,format=raw,readonly=on" \
        -drive "file=${build_vars},if=pflash,unit=1,format=raw" \
        -object "rng-random,id=rng0,filename=/dev/urandom" \
        -device "virtio-rng-pci,rng=rng0" \
        -rtc base=localtime

    sleep 1

    if [[ ! -f "$build_pid" ]]; then
        echo "Failed to start QEMU for phase 2. Check $build_log"
        exit 1
    fi

    pid=$(cat "$build_pid")
    echo "  QEMU started (PID: $pid)"
    echo ""
    echo "Watch progress:"
    echo "  Latest screen:  feh $screen_ppm      (auto-updates every 60s)"
    echo "  VNC viewer:     vncviewer localhost${build_vnc}"
    echo "  Manual control: telnet localhost ${build_monitor}"
    echo "  Force stop:     echo quit | nc -q1 localhost ${build_monitor}"
    echo ""
    echo "Waiting for install to complete and VM to shut down..."
    echo "  Soft cap: ${build_timeout}s (advisory only — VM will not be killed)"
    echo "  The VM shuts itself down when FirstLogonCommands finish."
    echo ""
    printf "  %-8s  %-10s  %-12s  %-10s  %s\n" "ELAPSED" "DISK" "WRITTEN" "RATE" "PHASE"

    # Wait for VM to shut down (FirstLogonCommands issue shutdown /s after setup).
    local soft_timeout_warned=0
    local last_disk_mtime
    last_disk_mtime=$(stat -c %Y "$build_disk" 2>/dev/null || echo 0)
    local last_disk_change=$elapsed
    last_disk_bytes=$(_disk_allocated_bytes "$build_disk")
    local start_disk_bytes=$last_disk_bytes
    while kill -0 "$pid" 2>/dev/null; do
        local now_disk_mtime now_disk_bytes
        now_disk_mtime=$(stat -c %Y "$build_disk" 2>/dev/null || echo 0)
        now_disk_bytes=$(_disk_allocated_bytes "$build_disk")

        if [[ "$now_disk_mtime" != "$last_disk_mtime" ]]; then
            last_disk_mtime="$now_disk_mtime"
            last_disk_change=$elapsed
        fi
        local since_change=$(( elapsed - last_disk_change ))

        # Advisory soft timeout — warn once, do not kill
        if (( elapsed >= build_timeout && soft_timeout_warned == 0 )); then
            echo ""
            echo "  [!] Build has been running ${elapsed}s (>${build_timeout}s soft cap)."
            echo "      VM is NOT being killed. Inspect via VNC: localhost${build_vnc}"
            echo "      Force stop: echo quit | nc -q1 localhost ${build_monitor}"
            echo ""
            soft_timeout_warned=1
        fi

        # Screendump every 60s via QEMU monitor. Silently ignore failures.
        if (( elapsed > 0 && elapsed % 60 == 0 )); then
            echo "screendump ${screen_ppm}.tmp" | nc -q1 localhost "$build_monitor" \
                >/dev/null 2>&1 && mv -f "${screen_ppm}.tmp" "$screen_ppm" 2>/dev/null || true
        fi

        # Progress line every 30s
        if (( elapsed % 30 == 0 && elapsed > 0 )); then
            local delta_bytes=$(( now_disk_bytes - last_disk_bytes ))
            local written_bytes=$(( now_disk_bytes - start_disk_bytes ))
            local rate_bps=$(( delta_bytes / 30 ))
            local disk_h written_h rate_h phase
            disk_h=$(numfmt --to=iec --suffix=B "$now_disk_bytes" 2>/dev/null || echo "?")
            written_h=$(numfmt --to=iec --suffix=B "$written_bytes" 2>/dev/null || echo "?")
            rate_h=$(numfmt --to=iec --suffix=B/s "$rate_bps" 2>/dev/null || echo "?")

            if (( since_change >= stall_threshold )); then
                phase="STALLED (no writes ${since_change}s)"
            elif (( rate_bps > 1024*1024 )); then
                phase="installing-windows"
            elif (( rate_bps > 0 )); then
                phase="configuring"
            else
                phase="reboot-or-idle"
            fi

            printf "  %-8s  %-10s  %-12s  %-10s  %s\n" \
                "$(printf '%dm%02ds' $((elapsed/60)) $((elapsed%60)))" \
                "$disk_h" "$written_h" "$rate_h" "$phase"

            last_disk_bytes=$now_disk_bytes
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

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
    rm -f "$build_disk" "$build_vars" "$build_rom" "$build_log"

    # Clean up TAP (will recreate for verification)
    if ip link show "$build_tap" &>/dev/null; then
        ip link set "$build_tap" down 2>/dev/null || true
        ip link delete "$build_tap" 2>/dev/null || true
    fi

    # Verify base image by booting and probing SSH
    echo ""
    echo "Verifying base image (quick boot + SSH probe)..."
    local verify_ok=0
    local verify_ip="192.168.50.200"
    local verify_user="testuser"
    local verify_name="base-verify"

    # Create overlay from new base image
    if windows_overlay_create "$verify_name" >/dev/null 2>&1; then
        # Recreate network for verification VM
        ensure_tap "$build_tap" "$BRIDGE_NAME" 2>/dev/null

        # Start VM quietly (using VNC :10 to avoid conflict)
        if windows_vm_start "$verify_name" "$verify_ip" "$build_tap" ":10" "7200" >/dev/null 2>&1; then
            echo "  Waiting for SSH at ${verify_user}@${verify_ip}..."

            # Wait up to 180s for SSH (Windows cold boot can take 2-3 minutes)
            local ssh_attempts=0
            while [[ $ssh_attempts -lt 60 ]]; do
                if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                       "${verify_user}@${verify_ip}" "echo ready" 2>/dev/null | grep -q ready; then
                    echo "  SSH verification: SUCCESS"
                    verify_ok=1
                    break
                fi
                ((ssh_attempts++))
                sleep 3
            done

            if [[ $verify_ok -eq 0 ]]; then
                echo "  SSH verification: FAILED (timed out after 180s)"
                echo "  WARNING: Base image may be incomplete. Check C:\\Windows\\Temp\\firstlogon.log"
            fi

            # Shut down verification VM
            windows_vm_stop "$verify_name" "7200" >/dev/null 2>&1 || true
        else
            echo "  WARNING: Could not start verification VM"
        fi

        # Clean up verification overlay
        windows_vm_destroy "$verify_name" "$build_tap" "7200" >/dev/null 2>&1 || true
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
