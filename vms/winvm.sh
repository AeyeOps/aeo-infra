#!/bin/bash
# Windows VM Management
# Uses golden image + copy-on-write overlays for instant, disposable Windows VMs
#
# Usage:
#   ./winvm.sh start <name> [--ip IP]    Start a new Windows VM from golden image
#   ./winvm.sh stop <name>               Graceful shutdown
#   ./winvm.sh destroy <name>            Full teardown (stop + delete overlay)
#   ./winvm.sh ssh <name>                Connect via SSH
#   ./winvm.sh exec <name> <cmd>         Run command on VM via SSH
#   ./winvm.sh status <name>             Check VM state
#   ./winvm.sh list                      List running Windows VMs
#   ./winvm.sh golden build              Build golden image (interactive, one-time)
#   ./winvm.sh golden status             Check if golden image exists
#   ./winvm.sh golden destroy            Remove golden image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library functions
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/windows.sh"

# Global defaults (shared with vm.sh)
STORAGE_DIR="${STORAGE_DIR:-/storage}"
BRIDGE_NAME="br-vm"
VM_SUBNET="192.168.50"
HOST_IP="${VM_SUBNET}.1"
WIN_DEFAULT_IP="${VM_SUBNET}.200"

# ─── Usage ─────────────────────────────────────────────────────────────

show_usage() {
    cat << 'EOF'
Usage: ./winvm.sh <command> [args]

Instance commands:
  start <name> [--ip IP]    Start a new Windows VM from golden image
  stop <name>               Graceful shutdown
  destroy <name>            Full teardown (stop + delete overlay)
  ssh <name>                Connect via SSH
  exec <name> <cmd>         Run command on VM via SSH
  status <name>             Check VM state
  list                      List running Windows VMs

Golden image commands:
  golden build              Build golden image (interactive, one-time)
  golden status             Check if golden image exists
  golden destroy            Remove golden image

Options:
  --ip IP       Override default IP (default: 192.168.50.200)
  --help, -h    Show this help

Examples:
  ./winvm.sh golden build              # One-time golden image creation
  ./winvm.sh start meshtest            # Instant Windows VM
  ./winvm.sh ssh meshtest              # SSH into it
  ./winvm.sh exec meshtest "hostname"  # Run a command
  ./winvm.sh destroy meshtest          # Tear it down
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

    # Check golden image
    if ! windows_golden_exists; then
        echo "Golden image not found at $GOLDEN_DIR"
        echo ""
        echo "Build one first:"
        echo "  sudo ./winvm.sh golden build"
        exit 1
    fi
    echo "  Golden image OK"

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
    echo "  This will delete the overlay (golden image is preserved)"
    echo ""

    windows_vm_destroy "$name"

    echo ""
    echo "VM 'winvm-${name}' destroyed (golden image untouched)"
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

# ─── Golden Image ─────────────────────────────────────────────────────

cmd_golden_status() {
    echo ""
    windows_golden_status
    echo ""
    if windows_golden_exists; then
        echo "Golden image is ready."
    else
        echo "Golden image not found."
        echo "  Run: sudo ./winvm.sh golden build"
    fi
}

cmd_golden_destroy() {
    require_root

    if ! windows_golden_exists; then
        echo "Golden image not found (nothing to destroy)"
        return 0
    fi

    echo "This will permanently delete the golden image:"
    echo "  $GOLDEN_WINDOWS_DISK"
    echo "  $GOLDEN_WINDOWS_VARS"
    echo "  $GOLDEN_WINDOWS_ROM"
    echo ""
    read -p "Type 'golden' to confirm: " confirm

    if [[ "$confirm" != "golden" ]]; then
        echo "Cancelled"
        return 1
    fi

    rm -f "$GOLDEN_WINDOWS_DISK" "$GOLDEN_WINDOWS_VARS" "$GOLDEN_WINDOWS_ROM"
    echo "Golden image destroyed"
}

cmd_golden_build() {
    require_root

    local iso_file="${STORAGE_DIR}/win11arm64.iso"
    local build_disk="${STORAGE_DIR}/golden-build-windows.img"
    local build_vars="${STORAGE_DIR}/golden-build-windows.vars"
    local build_rom="${STORAGE_DIR}/golden-build-windows.rom"
    local build_pid="/run/shm/golden-build-windows.pid"
    local build_log="/run/shm/golden-build-windows.log"
    local build_tap="tap-win-golden"
    local build_vnc=":9"
    local build_vnc_ws="5709"
    local build_monitor="7199"
    local build_mac="02:aa:bb:cc:dd:ee"

    echo ""
    echo "Windows Golden Image Builder"
    echo "======================================================="
    echo ""

    # Check for existing golden image
    if windows_golden_exists; then
        echo "Golden image already exists at $GOLDEN_DIR"
        echo "  To rebuild, first run: sudo ./winvm.sh golden destroy"
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

    echo "ISO found: $iso_file"
    echo ""

    # Create golden directory
    mkdir -p "$GOLDEN_DIR"

    # Create build disk (raw, 64G)
    echo "Creating 64G build disk..."
    qemu-img create -f raw "$build_disk" 64G

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

    echo ""
    echo "Starting QEMU with Windows ISO..."
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
        -name "golden-build-windows" \
        -serial pty \
        -device "qemu-xhci" \
        -device usb-kbd \
        -device usb-tablet \
        -netdev "tap,id=hostnet0,ifname=${build_tap},script=no,downscript=no" \
        -device "virtio-net-pci,netdev=hostnet0,mac=${build_mac}" \
        -drive "file=${iso_file},id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none" \
        -device "usb-storage,drive=cdrom0,bootindex=0,removable=on" \
        -object "iothread,id=io0" \
        -drive "file=${build_disk},id=data0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none" \
        -device "virtio-scsi-pci,id=scsi0,bus=pcie.0,iothread=io0" \
        -device "scsi-hd,drive=data0,bus=scsi0.0,bootindex=1" \
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

    cat << 'INSTRUCTIONS'
=======================================================
QEMU is running. Connect via VNC to complete installation.

  VNC:     localhost:9 (port 5909)
  Monitor: telnet localhost 7199

Installation steps:
  1. Connect to VNC and install Windows 11
  2. After install completes and you reach the desktop,
     open PowerShell as Administrator and run:

     # Enable OpenSSH Server
     Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
     Start-Service sshd
     Set-Service sshd -StartupType Automatic

     # Create test user with known password
     $pw = ConvertTo-SecureString 'TestPass123!' -AsPlainText -Force
     New-LocalUser -Name testuser -Password $pw -FullName 'Test User'
     Add-LocalGroupMember -Group Administrators -Member testuser

     # Configure network (static IP for bridge)
     New-NetIPAddress -InterfaceAlias 'Ethernet' -IPAddress 192.168.50.200 -PrefixLength 24 -DefaultGateway 192.168.50.1
     Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses 8.8.8.8

     # Install Tailscale
     winget install --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements --silent

  3. Shut down Windows cleanly: Start -> Power -> Shut down

=======================================================
Waiting for QEMU process to exit (or press Enter to finalize)...
INSTRUCTIONS

    # Wait for VM to shut down or user to press Enter
    while true; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "QEMU process exited."
            break
        fi
        if read -t 5 -r; then
            # User pressed Enter — check if VM is still running
            if kill -0 "$pid" 2>/dev/null; then
                echo "VM is still running. Sending ACPI shutdown..."
                echo "system_powerdown" | nc -q1 localhost "$build_monitor" 2>/dev/null || true
                echo "Waiting up to 60s for shutdown..."
                for i in {1..60}; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        echo "VM shut down."
                        break 2
                    fi
                    sleep 1
                done
                echo "Forcing quit..."
                echo "quit" | nc -q1 localhost "$build_monitor" 2>/dev/null || kill "$pid" 2>/dev/null || true
                sleep 2
            fi
            break
        fi
    done

    rm -f "$build_pid"

    echo ""
    echo "Converting raw disk to compressed qcow2..."
    qemu-img convert -f raw -O qcow2 -c "$build_disk" "$GOLDEN_WINDOWS_DISK"

    echo "Copying UEFI files to golden directory..."
    cp "$build_vars" "$GOLDEN_WINDOWS_VARS"
    cp "$build_rom" "$GOLDEN_WINDOWS_ROM"

    echo "Cleaning up build files..."
    rm -f "$build_disk" "$build_vars" "$build_rom" "$build_log"

    # Clean up TAP
    if ip link show "$build_tap" &>/dev/null; then
        ip link set "$build_tap" down 2>/dev/null || true
        ip link delete "$build_tap" 2>/dev/null || true
    fi

    echo ""
    echo "======================================================="
    echo "Golden image ready at $GOLDEN_DIR"
    echo ""
    local golden_size
    golden_size=$(du -h "$GOLDEN_WINDOWS_DISK" 2>/dev/null | cut -f1)
    echo "  Disk:  $GOLDEN_WINDOWS_DISK ($golden_size)"
    echo "  Vars:  $GOLDEN_WINDOWS_VARS"
    echo "  ROM:   $GOLDEN_WINDOWS_ROM"
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
        golden)
            [[ $# -lt 1 ]] && { echo "Error: golden subcommand required (build|status|destroy)"; exit 1; }
            local subcmd="$1"
            shift
            case "$subcmd" in
                build)   cmd_golden_build ;;
                status)  cmd_golden_status ;;
                destroy) cmd_golden_destroy ;;
                *)       echo "Unknown golden subcommand: $subcmd"; exit 1 ;;
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
