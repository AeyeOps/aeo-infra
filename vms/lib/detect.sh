#!/bin/bash
# VM State Detection Functions
# Determines current state of VM and prerequisites

# Detection result codes
declare -A STATE_CODES=(
    [NO_DISK]=0
    [CREATED]=1
    [INSTALLED]=2
    [RUNNING]=3
    [READY]=4
)

# Check if QEMU is installed
check_qemu_installed() {
    command -v qemu-system-aarch64 &>/dev/null
}

# Check if UEFI firmware is available
check_uefi_firmware() {
    [[ -f "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" ]]
}

# Check if genisoimage is installed
check_genisoimage() {
    command -v genisoimage &>/dev/null
}

# Check if storage directory exists
check_storage_dir() {
    [[ -d "${STORAGE_DIR:-/storage}" ]]
}

# Check if disk image exists
check_disk_exists() {
    local disk="${1:-$VM_DISK_FILE}"
    [[ -f "$disk" ]]
}

# Check if disk has an OS installed (has partitions)
check_disk_has_os() {
    local disk="${1:-$VM_DISK_FILE}"
    [[ -f "$disk" ]] && fdisk -l "$disk" 2>/dev/null | grep -q "^${disk}"
}

# Check if UEFI vars file exists with correct size
check_uefi_vars() {
    local vars="${1:-$VM_VARS_FILE}"
    local size_needed=67108864  # 64MB

    [[ -f "$vars" ]] && [[ $(stat -c%s "$vars" 2>/dev/null || echo 0) -ge $size_needed ]]
}

# Check if UEFI ROM exists with correct size
check_uefi_rom() {
    local rom="${1:-$VM_EFI_ROM}"
    local size_needed=67108864  # 64MB

    [[ -f "$rom" ]] && [[ $(stat -c%s "$rom" 2>/dev/null || echo 0) -eq $size_needed ]]
}

# Check if Ubuntu ISO exists and is complete (>2GB)
check_ubuntu_iso() {
    local iso
    iso=$(get_ubuntu_iso)

    if [[ -n "$iso" && -f "$iso" ]]; then
        local size
        size=$(stat -c%s "$iso" 2>/dev/null || echo 0)
        [[ $size -gt 2000000000 ]]
    else
        return 1
    fi
}

# Get path to Ubuntu ISO (prefer largest valid ISO)
get_ubuntu_iso() {
    # Find all Ubuntu ISOs and pick the largest one
    local storage="${STORAGE_DIR:-/storage}"
    local best_iso=""
    local best_size=0
    local iso size

    for iso in "$storage"/ubuntu-*-arm64.iso; do
        [[ -f "$iso" ]] || continue
        size=$(stat -c%s "$iso" 2>/dev/null) || continue
        if [[ $size -gt $best_size ]]; then
            best_size=$size
            best_iso=$iso
        fi
    done

    [[ -n "$best_iso" ]] && echo "$best_iso"
}

# Check if cloud-init ISO exists
check_cloud_init_iso() {
    local iso="${1:-$VM_CLOUD_INIT_FILE}"
    [[ -f "$iso" ]]
}

# Check if VM is running (via PID file or process grep)
check_vm_running() {
    local name="${1:-$VM_NAME}"
    local pid_file="${2:-$VM_PID_FILE}"

    # Check PID file first
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi

    # Fallback to process grep
    pgrep -f "qemu.*name.*${name}" &>/dev/null
}

# Get VM PID if running
get_vm_pid() {
    local name="${1:-$VM_NAME}"
    local pid_file="${2:-$VM_PID_FILE}"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi

    # Fallback to process grep
    pgrep -f "qemu.*name.*${name}" 2>/dev/null | head -1
}

# Check if IP is reachable
check_ip_reachable() {
    local ip="${1:-$VM_IP}"
    ping -c1 -W2 "$ip" &>/dev/null
}

# Check if SSH is accessible
check_ssh_accessible() {
    local name="${1:-$VM_NAME}"
    ssh -o ConnectTimeout=3 -o BatchMode=yes "$name" true 2>/dev/null
}

# Detect upstream network interface from default route
detect_upstream_interface() {
    ip route | grep default | head -1 | awk '{print $5}'
}

# Check if bridge exists
check_bridge_exists() {
    local bridge="${1:-br-vm}"
    ip link show "$bridge" &>/dev/null
}

# Check if bridge has correct IP
check_bridge_has_ip() {
    local bridge="${1:-br-vm}"
    local expected_ip="${2:-192.168.50.1}"
    ip addr show "$bridge" 2>/dev/null | grep -q "${expected_ip}/"
}

# Check if bridge is up
check_bridge_up() {
    local bridge="${1:-br-vm}"
    ip link show "$bridge" 2>/dev/null | grep -q "state UP"
}

# Check if TAP exists
check_tap_exists() {
    local tap="${1:-$VM_TAP_NAME}"
    ip link show "$tap" &>/dev/null
}

# Check if TAP is attached to bridge
check_tap_on_bridge() {
    local tap="${1:-$VM_TAP_NAME}"
    local bridge="${2:-br-vm}"
    ip link show "$tap" 2>/dev/null | grep -q "master ${bridge}"
}

# Check if TAP is up
check_tap_up() {
    local tap="${1:-$VM_TAP_NAME}"
    ip link show "$tap" 2>/dev/null | grep -q "state UP\|state UNKNOWN"
}

# Check if IP forwarding is enabled
check_ip_forwarding() {
    [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) == "1" ]]
}

# Check if NAT masquerade rule exists
check_nat_rule() {
    local upstream="${1:-$(detect_upstream_interface)}"
    local subnet="${2:-192.168.50.0/24}"
    iptables -t nat -C POSTROUTING -s "$subnet" -o "$upstream" -j MASQUERADE 2>/dev/null
}

# Check if forward rules exist
check_forward_rules() {
    local bridge="${1:-br-vm}"
    local upstream="${2:-$(detect_upstream_interface)}"

    iptables -C FORWARD -i "$bridge" -o "$upstream" -j ACCEPT 2>/dev/null && \
    iptables -C FORWARD -i "$upstream" -o "$bridge" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
}

# Check if SSH config entry exists
check_ssh_config_entry() {
    local name="${1:-$VM_NAME}"
    local config_file="${HOME}/.ssh/config"

    [[ -f "$config_file" ]] && grep -q "^Host ${name}\$" "$config_file"
}

# Check if VNC port is free
check_vnc_port_free() {
    local display="${1:-$VM_VNC_DISPLAY}"
    local port=$((5900 + ${display#:}))
    ! ss -tln 2>/dev/null | grep -q ":${port}\s"
}

# Determine overall VM state
determine_vm_state() {
    local name="${1:-$VM_NAME}"

    if check_vm_running "$name"; then
        if check_ssh_accessible "$name"; then
            echo "READY"
        else
            echo "RUNNING"
        fi
    elif check_disk_has_os "$VM_DISK_FILE"; then
        echo "INSTALLED"
    elif check_disk_exists "$VM_DISK_FILE"; then
        echo "CREATED"
    else
        echo "NO_DISK"
    fi
}

# Print a status check line
# Usage: print_check <passed> <label> [detail]
print_check() {
    local passed="$1"
    local label="$2"
    local detail="${3:-}"

    if [[ "$passed" == "1" || "$passed" == "true" ]]; then
        printf "  ✓ %s" "$label"
    else
        printf "  ✗ %s" "$label"
    fi

    if [[ -n "$detail" ]]; then
        printf " (%s)" "$detail"
    fi
    printf "\n"
}
