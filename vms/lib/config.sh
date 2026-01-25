#!/bin/bash
# VM Configuration Management
# Handles VM registry, IP allocation, and config file operations

CONFIG_DIR="${CONFIG_DIR:-/storage/vms}"
ALLOCATIONS_FILE="${CONFIG_DIR}/ip-allocations"
VM_SUBNET="${VM_SUBNET:-192.168.50}"
STORAGE_DIR="${STORAGE_DIR:-/storage}"

# Ensure config directory exists
# Returns 0 if directory exists or was created, 1 if failed
ensure_config_dir() {
    if [[ -d "$CONFIG_DIR" ]]; then
        return 0
    fi

    if mkdir -p "$CONFIG_DIR" 2>/dev/null; then
        return 0
    fi

    echo "Error: Cannot create config directory $CONFIG_DIR (need sudo?)" >&2
    return 1
}

# Load VM configuration file
# Returns 0 if config exists and was loaded, 1 otherwise
load_vm_config() {
    local name="$1"
    local config_file="${CONFIG_DIR}/${name}.conf"

    if [[ ! -f "$config_file" ]]; then
        return 1
    fi

    # shellcheck source=/dev/null
    source "$config_file"
    return 0
}

# Get next available IP in the subnet
# Reads allocations file, finds gaps or appends
get_next_ip() {
    ensure_config_dir

    local used_ips=()
    if [[ -f "$ALLOCATIONS_FILE" ]]; then
        while IFS='|' read -r name ip mac vnc; do
            [[ -n "$ip" ]] && used_ips+=("${ip##*.}")  # Extract last octet
        done < <(grep -v '^#' "$ALLOCATIONS_FILE" 2>/dev/null)
    fi

    # Find first available IP starting at .10
    for i in {10..254}; do
        local found=0
        for used in "${used_ips[@]}"; do
            if [[ "$used" == "$i" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "${VM_SUBNET}.${i}"
            return 0
        fi
    done

    echo "Error: No available IPs in ${VM_SUBNET}.0/24" >&2
    return 1
}

# Get next available VNC display number
get_next_vnc() {
    ensure_config_dir

    local used_vncs=()
    if [[ -f "$ALLOCATIONS_FILE" ]]; then
        while IFS='|' read -r name ip mac vnc; do
            [[ -n "$vnc" ]] && used_vncs+=("$vnc")
        done < <(grep -v '^#' "$ALLOCATIONS_FILE" 2>/dev/null)
    fi

    # Find first available VNC display starting at 1 (0 reserved for Windows)
    for i in {1..99}; do
        local found=0
        for used in "${used_vncs[@]}"; do
            if [[ "$used" == "$i" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "$i"
            return 0
        fi
    done

    echo "Error: No available VNC displays" >&2
    return 1
}

# Generate a random MAC address with local admin bit set
generate_mac() {
    printf '02:%02x:%02x:%02x:%02x:%02x\n' \
        $((RANDOM % 256)) $((RANDOM % 256)) \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

# Create new VM configuration interactively
create_vm_config() {
    local name="$1"
    local config_file="${CONFIG_DIR}/${name}.conf"

    ensure_config_dir

    echo "Creating configuration for VM '$name'..."
    echo ""

    # Get next available IP
    local ip
    ip=$(get_next_ip) || return 1

    # Get next available VNC display
    local vnc
    vnc=$(get_next_vnc) || return 1

    # Generate MAC address
    local mac
    mac=$(generate_mac)

    # Get current user (for SSH key)
    local user="${SUDO_USER:-${USER:-root}}"

    # Default values
    local ram="8G"
    local cpus="4"
    local disk_size="64G"

    echo "  VM Name:      $name"
    echo "  IP Address:   $ip"
    echo "  MAC Address:  $mac"
    echo "  VNC Display:  :$vnc (port 590${vnc})"
    echo "  RAM:          $ram"
    echo "  CPUs:         $cpus"
    echo "  Disk Size:    $disk_size"
    echo "  User:         $user"
    echo ""

    # Write config file
    cat > "$config_file" << EOF
# VM Configuration for ${name}
# Generated: $(date -Iseconds)

VM_NAME="${name}"
VM_IP="${ip}"
VM_MAC="${mac}"
VM_RAM="${ram}"
VM_CPUS="${cpus}"
VM_DISK_SIZE="${disk_size}"
VM_VNC_DISPLAY=":${vnc}"
VM_VNC_WS_PORT="570${vnc}"
VM_MONITOR_PORT="710${vnc}"
VM_USER="${user}"

# File paths (defaults to /storage/\${VM_NAME}.* pattern)
# Uncomment to override:
# VM_DISK_FILE="/storage/${name}.img"
# VM_VARS_FILE="/storage/${name}.vars"
# VM_CLOUD_INIT_FILE="/storage/${name}-cloud-init.iso"
# VM_TAP_NAME="tap-${name}"
EOF

    # Update allocations file (idempotent - check before adding)
    if ! grep -q "^${name}:" "$ALLOCATIONS_FILE" 2>/dev/null; then
        echo "${name}|${ip}|${mac}|${vnc}" >> "$ALLOCATIONS_FILE"
    fi

    echo "  Config saved to: $config_file"
    return 0
}

# Detect if legacy VM files exist and are unclaimed
detect_legacy_vm() {
    # Check for legacy file naming pattern
    [[ -f "${STORAGE_DIR}/ubuntu.img" ]] || return 1
    [[ -f "${STORAGE_DIR}/ubuntu.vars" ]] || return 1

    # Check if any existing config already claims these legacy files
    if [[ -d "$CONFIG_DIR" ]]; then
        if grep -l "VM_DISK_FILE=.*/ubuntu\.img" "${CONFIG_DIR}"/*.conf 2>/dev/null | head -1 | grep -q .; then
            # Already claimed by another VM config
            return 1
        fi
    fi

    return 0
}

# Create migration config for existing VM with legacy naming
migrate_legacy_config() {
    local name="$1"
    local config_file="${CONFIG_DIR}/${name}.conf"

    ensure_config_dir

    if [[ -f "$config_file" ]]; then
        echo "Config already exists: $config_file"
        return 1
    fi

    echo "  → Detected legacy VM files, migrating to '$name' config..."

    # Get current user
    local user="${SUDO_USER:-${USER:-root}}"

    # Legacy paths from existing scripts
    cat > "$config_file" << EOF
# VM Configuration for ${name}
# Migrated from legacy ubuntu.* naming
# Generated: $(date -Iseconds)

VM_NAME="${name}"
VM_IP="192.168.50.10"
VM_MAC="02:58:EC:4C:35:34"
VM_RAM="8G"
VM_CPUS="4"
VM_DISK_SIZE="64G"
VM_VNC_DISPLAY=":1"
VM_VNC_WS_PORT="5701"
VM_MONITOR_PORT="7101"
VM_USER="${user}"

# Legacy file paths (override default naming pattern)
VM_DISK_FILE="/storage/ubuntu.img"
VM_VARS_FILE="/storage/ubuntu.vars"
VM_EFI_ROM="/storage/ubuntu-efi.rom"
VM_CLOUD_INIT_FILE="/storage/ubuntu-cloud-init.iso"
VM_TAP_NAME="tap-ubuntu"
EOF

    # Update allocations file
    if ! grep -q "^${name}:" "$ALLOCATIONS_FILE" 2>/dev/null; then
        echo "${name}|192.168.50.10|02:58:EC:4C:35:34|1" >> "$ALLOCATIONS_FILE"
    fi

    echo "  Config saved to: $config_file"
    echo "  Legacy paths preserved:"
    echo "    Disk:       /storage/ubuntu.img"
    echo "    UEFI vars:  /storage/ubuntu.vars"
    echo "    Cloud-init: /storage/ubuntu-cloud-init.iso"
    echo "    TAP:        tap-ubuntu"
    return 0
}

# Get effective file paths for a VM (with fallback to defaults)
get_vm_paths() {
    local name="$1"

    # Use config values if set, otherwise default pattern
    VM_DISK_FILE="${VM_DISK_FILE:-${STORAGE_DIR}/${name}.img}"
    VM_VARS_FILE="${VM_VARS_FILE:-${STORAGE_DIR}/${name}.vars}"
    VM_CLOUD_INIT_FILE="${VM_CLOUD_INIT_FILE:-${STORAGE_DIR}/${name}-cloud-init.iso}"
    VM_TAP_NAME="${VM_TAP_NAME:-tap-${name}}"
    VM_EFI_ROM="${VM_EFI_ROM:-${STORAGE_DIR}/${name}-efi.rom}"

    # Runtime files (not configurable)
    VM_PID_FILE="/run/shm/qemu-${name}.pid"
    VM_LOG_FILE="/run/shm/qemu-${name}.log"
    VM_SERIAL_LOG="/run/shm/qemu-${name}.serial"
}

# List all configured VMs
list_vms() {
    if [[ ! -d "$CONFIG_DIR" ]] || [[ ! -f "$ALLOCATIONS_FILE" ]]; then
        echo "No VMs configured yet"
        echo ""
        echo "To create a new VM:  sudo ./vm.sh <name>"
        return 0
    fi

    printf "%-10s %-15s %-19s %s\n" "NAME" "IP" "MAC" "VNC"
    printf "%-10s %-15s %-19s %s\n" "----" "--" "---" "---"

    while IFS='|' read -r name ip mac vnc; do
        [[ "$name" =~ ^# ]] && continue
        [[ -z "$name" ]] && continue
        printf "%-10s %-15s %-19s :%s\n" "$name" "$ip" "$mac" "$vnc"
    done < "$ALLOCATIONS_FILE"
}
