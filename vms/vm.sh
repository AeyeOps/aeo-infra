#!/bin/bash
# VM Management Script
# Single entry point for managing Ubuntu/Linux VMs
#
# Usage: ./vm.sh <name> [action]
#
# Actions:
#   (none)     Auto-detect state and do what's needed
#   status     Show detailed state without changing anything
#   start      Start VM (install mode if OS not detected)
#   stop       Graceful shutdown
#   reinstall  Wipe and reinstall OS (keeps config/IP/SSH alias)
#   ssh        Connect via SSH
#   console    Attach to serial console
#   destroy    Remove VM completely (with confirmation)
#   list       List all configured VMs
#
# Examples:
#   ./vm.sh ubu1            # Auto-detect and fix/start
#   ./vm.sh ubu1 status     # Just show state
#   ./vm.sh ubu1 reinstall  # Fresh OS install
#   ./vm.sh ubu2            # Create new VM named ubu2

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library functions
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/storage.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

# Global defaults
STORAGE_DIR="${STORAGE_DIR:-/storage}"
CONFIG_DIR="${CONFIG_DIR:-/storage/vms}"
BRIDGE_NAME="br-vm"
VM_SUBNET="192.168.50"
HOST_IP="${VM_SUBNET}.1"

# Usage help
show_usage() {
    cat << 'EOF'
Usage: ./vm.sh <name> [action]

Actions:
  (none)    Auto-detect state and do what's needed
  status    Show detailed state without changing anything
  start     Start VM (install mode if OS not detected)
  stop      Graceful shutdown
  reinstall Wipe and reinstall OS (keeps config/IP/SSH alias)
  ssh       Connect via SSH
  console   Attach to serial console
  destroy   Remove VM completely (with confirmation)
  list      List all configured VMs

Options:
  --help, -h  Show this help

Examples:
  ./vm.sh ubu1            # Auto-detect and fix/start
  ./vm.sh ubu1 status     # Just show state
  ./vm.sh ubu1 reinstall  # Fresh OS install, keep identity
  ./vm.sh ubu2            # Create new VM named ubu2
  ./vm.sh list            # List all VMs
EOF
}

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This action requires root privileges (sudo)"
        exit 1
    fi
}

# Ensure system prerequisites are installed
ensure_system_prereqs() {
    local needs_install=""

    if ! check_qemu_installed; then
        needs_install="qemu-system-arm"
    fi

    if ! check_uefi_firmware; then
        needs_install="$needs_install qemu-efi-aarch64"
    fi

    if ! check_genisoimage; then
        needs_install="$needs_install genisoimage"
    fi

    if [[ -n "$needs_install" ]]; then
        echo "  ✗ Missing packages:$needs_install"
        echo "    → Installing..."
        apt-get update && apt-get install -y $needs_install
        echo "  ✓ System packages installed"
    else
        echo "  ✓ System packages OK"
    fi
}

# Start VM in normal or install mode
start_vm() {
    local mode="${1:-normal}"  # normal or install

    # Check VNC port is free
    if ! check_vnc_port_free "$VM_VNC_DISPLAY"; then
        echo "  ✗ VNC port for display ${VM_VNC_DISPLAY} is already in use"
        echo "    Another VM may be running on this display"
        return 1
    fi

    local iso_file
    iso_file=$(get_ubuntu_iso)

    # Build QEMU command
    local qemu_cmd=(
        qemu-system-aarch64
        -nodefaults
        -cpu host
        -smp "${VM_CPUS},sockets=1,dies=1,cores=${VM_CPUS},threads=1"
        -m "$VM_RAM"
        -machine "type=virt,secure=off,gic-version=max,dump-guest-core=off,accel=kvm"
        -enable-kvm

        # Display: VNC with websocket
        -display "vnc=${VM_VNC_DISPLAY},websocket=${VM_VNC_WS_PORT}"
        -device ramfb

        # Monitor for QEMU control
        -monitor "telnet:localhost:${VM_MONITOR_PORT},server,nowait,nodelay"

        # Daemonize
        -daemonize
        -D "$VM_LOG_FILE"
        -pidfile "$VM_PID_FILE"
        -name "${VM_NAME},process=${VM_NAME},debug-threads=on"

        # Serial console - log to file for monitoring
        -serial "file:${VM_SERIAL_LOG}"

        # USB controller + input devices
        -device "qemu-xhci,id=xhci,p2=7,p3=7"
        -device usb-kbd
        -device usb-tablet

        # Network: TAP interface
        -netdev "tap,id=hostnet0,ifname=${VM_TAP_NAME},script=no,downscript=no"
        -device "virtio-net-pci,id=net0,netdev=hostnet0,romfile=,mac=${VM_MAC}"

        # Boot disk: virtio-blk
        -drive "file=${VM_DISK_FILE},id=disk0,format=raw,cache=none,aio=native,discard=on,detect-zeroes=on,if=none"
        -device "virtio-blk-pci,drive=disk0,bootindex=1"

        # RTC
        -rtc base=localtime

        # UEFI firmware
        -drive "file=${VM_EFI_ROM},if=pflash,unit=0,format=raw,readonly=on"
        -drive "file=${VM_VARS_FILE},if=pflash,unit=1,format=raw"

        # Random number generator
        -object "rng-random,id=objrng0,filename=/dev/urandom"
        -device "virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0"
    )

    # Add ISO for installation if requested
    if [[ "$mode" == "install" ]]; then
        if [[ -z "$iso_file" || ! -f "$iso_file" ]]; then
            echo "  ✗ Ubuntu ISO not found. Run: sudo ./vm.sh $VM_NAME"
            return 1
        fi

        echo "  Starting '$VM_NAME' (installation mode)..."

        # Check for extracted kernel/initrd for direct boot (enables autoinstall without prompt)
        local boot_dir="${STORAGE_DIR}/boot"
        if [[ -f "${boot_dir}/vmlinuz" && -f "${boot_dir}/initrd" ]]; then
            echo "    (using direct kernel boot with autoinstall)"
            qemu_cmd+=(
                # Direct kernel boot - allows passing autoinstall on cmdline
                -kernel "${boot_dir}/vmlinuz"
                -initrd "${boot_dir}/initrd"
                -append "autoinstall --- console=ttyAMA0,115200 console=tty0"
            )
        fi

        qemu_cmd+=(
            # Installation ISO
            -drive "file=${iso_file},id=cdrom0,format=raw,cache=unsafe,readonly=on,media=cdrom,if=none"
            -device "usb-storage,drive=cdrom0,bootindex=0,removable=on"
        )

        # Add cloud-init ISO for automated install
        if [[ -f "$VM_CLOUD_INIT_FILE" ]]; then
            qemu_cmd+=(
                -drive "file=${VM_CLOUD_INIT_FILE},id=cidata,format=raw,readonly=on,media=cdrom,if=none"
                -device "usb-storage,drive=cidata,removable=on"
            )
            echo "    (cloud-init config attached)"
        fi
    else
        echo "  Starting '$VM_NAME' (normal boot)..."
    fi

    # Execute
    "${qemu_cmd[@]}"

    sleep 1

    if [[ -f "$VM_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VM_PID_FILE")
        echo "  ✓ QEMU started (PID: $pid)"
        echo "  ✓ VNC available at localhost${VM_VNC_DISPLAY}"
        return 0
    else
        echo "  ✗ Failed to start VM. Check $VM_LOG_FILE"
        return 1
    fi
}

# Stop VM gracefully
stop_vm() {
    if ! check_vm_running "$VM_NAME" "$VM_PID_FILE"; then
        echo "VM '$VM_NAME' is not running"
        return 0
    fi

    local pid
    pid=$(get_vm_pid "$VM_NAME" "$VM_PID_FILE")

    echo "Stopping VM '$VM_NAME'..."

    # Try graceful ACPI shutdown first
    echo "  Sending ACPI shutdown..."
    echo "system_powerdown" | nc -q1 localhost "$VM_MONITOR_PORT" 2>/dev/null || true

    echo "  Waiting for VM to shut down (max 30s)..."
    for i in {1..30}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "  ✓ VM shut down cleanly"
            rm -f "$VM_PID_FILE"
            return 0
        fi
        sleep 1
    done

    echo "  VM didn't respond to ACPI shutdown, forcing quit..."
    echo "quit" | nc -q1 localhost "$VM_MONITOR_PORT" 2>/dev/null || kill "$pid" 2>/dev/null || true

    sleep 2
    rm -f "$VM_PID_FILE"
    echo "  Done"
}

# Show detailed status
show_status() {
    echo ""
    echo "VM: $VM_NAME"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    # System Prerequisites
    echo "System Prerequisites"
    print_check "$(check_qemu_installed && echo 1 || echo 0)" "QEMU installed" "qemu-system-aarch64"
    print_check "$(check_uefi_firmware && echo 1 || echo 0)" "UEFI firmware available"
    print_check "$(check_genisoimage && echo 1 || echo 0)" "genisoimage installed"
    echo ""

    # Storage
    show_storage_status
    echo ""

    # Network
    show_network_status
    echo ""

    # Runtime
    echo "Runtime"
    if check_vm_running "$VM_NAME" "$VM_PID_FILE"; then
        local pid
        pid=$(get_vm_pid "$VM_NAME" "$VM_PID_FILE")
        print_check 1 "VM process: running" "PID $pid"
        print_check 1 "VNC: localhost${VM_VNC_DISPLAY}" "port 590${VM_VNC_DISPLAY#:}"
        print_check 1 "Monitor: telnet localhost ${VM_MONITOR_PORT}"

        if check_ip_reachable "$VM_IP"; then
            print_check 1 "Network: $VM_IP reachable"
        else
            print_check 0 "Network: $VM_IP not reachable"
        fi

        if check_ssh_accessible "$VM_NAME"; then
            print_check 1 "SSH: accessible" "ssh $VM_NAME"
        else
            print_check 0 "SSH: not accessible"
        fi
    else
        print_check 0 "VM process: not running"
    fi
    echo ""

    # Host Config
    show_ssh_config_status "$VM_NAME" "$VM_IP"
    echo ""

    # State summary
    local state
    state=$(determine_vm_state "$VM_NAME")
    echo "State: $state"
}

# Auto-detect and fix/start
auto_action() {
    echo ""
    echo "VM: $VM_NAME"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    require_root

    echo "Checking prerequisites..."
    ensure_system_prereqs
    ensure_storage_ready
    ensure_network_ready "$VM_TAP_NAME" "$BRIDGE_NAME"
    ensure_ssh_config "$VM_NAME" "$VM_IP" "$VM_USER"
    echo ""

    echo "Checking VM state..."
    if check_vm_running "$VM_NAME" "$VM_PID_FILE"; then
        local pid
        pid=$(get_vm_pid "$VM_NAME" "$VM_PID_FILE")
        echo "  • VM is running (PID: $pid)"

        if check_ssh_accessible "$VM_NAME"; then
            echo ""
            echo "═══════════════════════════════════════════════════════"
            echo "✓ VM '$VM_NAME' is ready"
            echo ""
            echo "  SSH:     ssh $VM_NAME"
            echo "  VNC:     localhost${VM_VNC_DISPLAY} (port 590${VM_VNC_DISPLAY#:})"
            echo "  Monitor: telnet localhost ${VM_MONITOR_PORT}"
            return 0
        else
            echo "  • SSH not yet accessible"
            wait_for_ssh "$VM_NAME" 30 && {
                echo ""
                echo "═══════════════════════════════════════════════════════"
                echo "✓ VM '$VM_NAME' is ready"
                echo ""
                echo "  SSH:     ssh $VM_NAME"
                echo "  VNC:     localhost${VM_VNC_DISPLAY} (port 590${VM_VNC_DISPLAY#:})"
                echo "  Monitor: telnet localhost ${VM_MONITOR_PORT}"
            }
            return 0
        fi
    fi

    # VM not running - determine boot mode
    if check_disk_has_os "$VM_DISK_FILE"; then
        echo "  • Disk has OS installed"
        echo "  • VM not running"
        echo ""
        start_vm normal
    else
        echo "  • Disk is empty (no OS)"
        echo "  • Starting installation..."
        echo ""

        # Ensure ISO is available
        if ! check_ubuntu_iso; then
            echo "  ✗ Ubuntu ISO needed for installation"
            ensure_ubuntu_iso
        fi

        start_vm install
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "Installation in progress"
        echo ""
        echo "  VNC:      localhost${VM_VNC_DISPLAY} (port 590${VM_VNC_DISPLAY#:})"
        echo "  User:     $VM_USER"
        echo "  Password: ubuntu (change after install)"
        echo ""
        echo "After installation completes, run:"
        echo "  ./vm.sh $VM_NAME"
        return 0
    fi

    # Wait for SSH after normal boot
    echo ""
    wait_for_ssh "$VM_NAME" 30 && {
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "✓ VM '$VM_NAME' is ready"
        echo ""
        echo "  SSH:     ssh $VM_NAME"
        echo "  VNC:     localhost${VM_VNC_DISPLAY} (port 590${VM_VNC_DISPLAY#:})"
        echo "  Monitor: telnet localhost ${VM_MONITOR_PORT}"
    } || {
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "⚠ VM '$VM_NAME' started but SSH not accessible"
        echo ""
        echo "  VNC:     localhost${VM_VNC_DISPLAY} (port 590${VM_VNC_DISPLAY#:})"
        echo "  Monitor: telnet localhost ${VM_MONITOR_PORT}"
    }
}

# Destroy VM completely
destroy_vm() {
    require_root

    echo "This will permanently delete VM '$VM_NAME' and all its data:"
    echo "  - Disk image: $VM_DISK_FILE"
    echo "  - UEFI vars:  $VM_VARS_FILE"
    echo "  - UEFI ROM:   $VM_EFI_ROM"
    echo "  - Cloud-init: $VM_CLOUD_INIT_FILE"
    echo "  - TAP:        $VM_TAP_NAME"
    echo "  - SSH config entry"
    echo ""
    read -p "Type '$VM_NAME' to confirm destruction: " confirm

    if [[ "$confirm" != "$VM_NAME" ]]; then
        echo "Cancelled"
        return 1
    fi

    # Stop VM if running
    if check_vm_running "$VM_NAME" "$VM_PID_FILE"; then
        stop_vm
    fi

    # Remove storage
    remove_storage "$VM_NAME"

    # Remove TAP
    remove_tap "$VM_TAP_NAME"

    # Remove SSH config
    remove_ssh_config_entry "$VM_NAME"

    # Remove config file
    local config_file="${CONFIG_DIR}/${VM_NAME}.conf"
    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        echo "  Removed: $config_file"
    fi

    # Remove from allocations
    if [[ -f "$ALLOCATIONS_FILE" ]]; then
        sed -i "/^${VM_NAME}:/d" "$ALLOCATIONS_FILE"
    fi

    echo ""
    echo "✓ VM '$VM_NAME' destroyed"
}

# Reinstall VM - wipe disk and cloud-init, keep config/identity
reinstall_vm() {
    require_root

    echo "This will reinstall VM '$VM_NAME' (keeps IP, config, SSH alias):"
    echo "  - Wipe disk:        $VM_DISK_FILE"
    echo "  - Regenerate:       $VM_CLOUD_INIT_FILE"
    echo ""
    read -p "Type 'reinstall' to confirm: " confirm

    if [[ "$confirm" != "reinstall" ]]; then
        echo "Cancelled"
        return 1
    fi

    # Stop VM if running
    if check_vm_running "$VM_NAME" "$VM_PID_FILE"; then
        echo "Stopping VM..."
        stop_vm
    fi

    # Wipe disk partition table (keeps file, clears first MB)
    if [[ -f "$VM_DISK_FILE" ]]; then
        echo "  → Wiping disk partition table..."
        dd if=/dev/zero of="$VM_DISK_FILE" bs=1M count=1 conv=notrunc 2>/dev/null
    fi

    # Remove cloud-init ISO to force regeneration
    if [[ -f "$VM_CLOUD_INIT_FILE" ]]; then
        echo "  → Removing cloud-init ISO..."
        rm -f "$VM_CLOUD_INIT_FILE"
    fi

    # Reset UEFI vars
    if [[ -f "$VM_VARS_FILE" ]]; then
        echo "  → Resetting UEFI vars..."
        truncate -s 64M "$VM_VARS_FILE"
    fi

    echo ""
    echo "✓ VM '$VM_NAME' ready for reinstall"
    echo ""
    echo "Starting fresh installation..."
    echo ""

    # Now do the normal auto-action which will detect empty disk and install
    auto_action
}

# Connect to VM console (serial log)
connect_console() {
    if ! check_vm_running "$VM_NAME" "$VM_PID_FILE"; then
        echo "VM '$VM_NAME' is not running"
        return 1
    fi

    if [[ -f "$VM_SERIAL_LOG" ]]; then
        echo "Following serial console: $VM_SERIAL_LOG"
        echo "Press Ctrl+C to stop"
        tail -f "$VM_SERIAL_LOG"
    else
        echo "Serial log not found: $VM_SERIAL_LOG"
        echo "Try VNC instead: localhost${VM_VNC_DISPLAY}"
        return 1
    fi
}

# Main entry point
main() {
    local action=""
    local name=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_usage
                exit 0
                ;;
            list)
                list_vms
                exit 0
                ;;
            status|start|stop|ssh|console|destroy|reinstall)
                if [[ -z "$name" ]]; then
                    echo "Error: VM name required before action"
                    show_usage
                    exit 1
                fi
                action="$1"
                shift
                ;;
            -*)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    action="$1"
                fi
                shift
                ;;
        esac
    done

    # Require name for most actions
    if [[ -z "$name" ]]; then
        show_usage
        exit 1
    fi

    # Load or create config
    if ! load_vm_config "$name"; then
        # Check for legacy VM files to auto-migrate
        if detect_legacy_vm; then
            require_root
            migrate_legacy_config "$name"
            load_vm_config "$name"
        else
            echo "No configuration found for VM '$name'"
            echo ""
            read -p "Create new VM '$name'? [y/N] " create_new
            if [[ "$create_new" =~ ^[Yy] ]]; then
                require_root
                create_vm_config "$name"
                load_vm_config "$name"
            else
                exit 1
            fi
        fi
    fi

    # Set effective file paths
    get_vm_paths "$name"

    # Execute action
    case "$action" in
        status)
            show_status
            ;;
        start)
            require_root
            if check_vm_running "$VM_NAME" "$VM_PID_FILE"; then
                echo "VM '$VM_NAME' is already running"
                exit 1
            fi
            ensure_network_ready "$VM_TAP_NAME" "$BRIDGE_NAME"
            if check_disk_has_os "$VM_DISK_FILE"; then
                start_vm normal
            else
                # Ensure ISO is available for installation
                if ! check_ubuntu_iso; then
                    echo "Ubuntu ISO needed for installation..."
                    ensure_ubuntu_iso
                fi
                start_vm install
            fi
            ;;
        stop)
            require_root
            stop_vm
            ;;
        ssh)
            if ! check_ssh_accessible "$VM_NAME"; then
                echo "SSH not accessible for '$VM_NAME'"
                exit 1
            fi
            exec ssh "$VM_NAME"
            ;;
        console)
            connect_console
            ;;
        destroy)
            destroy_vm
            ;;
        reinstall)
            reinstall_vm
            ;;
        "")
            auto_action
            ;;
        *)
            echo "Unknown action: $action"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
