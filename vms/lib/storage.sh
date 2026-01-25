#!/bin/bash
# VM Storage Management
# Disk images, UEFI files, ISO management

STORAGE_DIR="${STORAGE_DIR:-/storage}"
ISO_URL="${ISO_URL:-https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.3-live-server-arm64.iso}"

# Ensure storage directory exists
ensure_storage_dir() {
    if [[ ! -d "$STORAGE_DIR" ]]; then
        echo "    → Creating $STORAGE_DIR..."
        mkdir -p "$STORAGE_DIR"
        chmod 755 "$STORAGE_DIR"
    fi
}

# Create disk image if it doesn't exist
ensure_disk_exists() {
    local disk="${1:-$VM_DISK_FILE}"
    local size="${2:-$VM_DISK_SIZE}"

    if [[ ! -f "$disk" ]]; then
        echo "    → Creating ${size} disk image: $disk..."
        qemu-img create -f raw "$disk" "$size"
    fi
}

# Create UEFI vars file if needed
ensure_uefi_vars() {
    local vars="${1:-$VM_VARS_FILE}"
    local size_needed=67108864  # 64MB

    if [[ ! -f "$vars" ]]; then
        echo "    → Creating UEFI vars file: $vars..."
        truncate -s 64M "$vars"
    elif [[ $(stat -c%s "$vars" 2>/dev/null || echo 0) -lt $size_needed ]]; then
        echo "    → Resizing UEFI vars file to 64MB..."
        truncate -s 64M "$vars"
    fi
}

# Create padded UEFI ROM from system firmware
ensure_uefi_rom() {
    local rom="${1:-$VM_EFI_ROM}"
    local size_needed=67108864  # 64MB
    local source="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"

    if [[ ! -f "$source" ]]; then
        echo "    ✗ UEFI firmware not found: $source"
        return 1
    fi

    if [[ ! -f "$rom" ]] || [[ $(stat -c%s "$rom" 2>/dev/null || echo 0) -ne $size_needed ]]; then
        echo "    → Creating 64MB UEFI ROM: $rom..."
        truncate -s 64M "$rom"
        dd if="$source" of="$rom" conv=notrunc 2>/dev/null
    fi
}

# Download Ubuntu ISO if needed
ensure_ubuntu_iso() {
    local iso_file
    iso_file=$(get_ubuntu_iso)

    if [[ -z "$iso_file" ]]; then
        iso_file="${STORAGE_DIR}/ubuntu-24.04.3-server-arm64.iso"
    fi

    if [[ ! -f "$iso_file" ]]; then
        echo "    → Downloading Ubuntu 24.04 Server ARM64..."
        wget -c -O "$iso_file" "$ISO_URL"
    else
        local size
        size=$(stat -c%s "$iso_file" 2>/dev/null || echo 0)
        if [[ $size -lt 2000000000 ]]; then
            echo "    → Resuming Ubuntu ISO download..."
            wget -c -O "$iso_file" "$ISO_URL"
        fi
    fi
}

# Create cloud-init ISO for automated installation
create_cloud_init_iso() {
    local iso="${1:-$VM_CLOUD_INIT_FILE}"
    local name="${2:-$VM_NAME}"
    local ip="${3:-$VM_IP}"
    local user="${4:-$VM_USER}"
    local gateway="${5:-${VM_SUBNET}.1}"

    # Find SSH public key
    local ssh_key=""
    local ssh_key_file
    local key_user="${SUDO_USER:-$user}"

    for key_type in id_ed25519 id_rsa; do
        ssh_key_file="/home/${key_user}/.ssh/${key_type}.pub"
        if [[ -f "$ssh_key_file" ]]; then
            ssh_key=$(cat "$ssh_key_file")
            echo "    Using SSH key: $ssh_key_file"
            break
        fi
    done

    if [[ -z "$ssh_key" ]]; then
        echo "    Warning: No SSH key found, password auth only"
    fi

    # Create temp directory
    local cloud_init_dir
    cloud_init_dir=$(mktemp -d)
    trap "rm -rf $cloud_init_dir" RETURN

    # Generate password hash for 'ubuntu'
    local password_hash
    password_hash=$(openssl passwd -6 -salt "$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')" "ubuntu")

    # Create meta-data
    cat > "$cloud_init_dir/meta-data" << EOF
instance-id: ${name}
local-hostname: ${name}
EOF

    # Create user-data with autoinstall
    # Fully non-interactive: no prompts, no update checks, auto-reboot
    cat > "$cloud_init_dir/user-data" << EOF
#cloud-config
autoinstall:
  version: 1
  interactive-sections: []    # No interactive prompts
  refresh-installer:
    update: no                # Don't pause to update installer
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${name}
    username: ${user}
    # Password: ubuntu (change on first login recommended)
    password: '${password_hash}'
  ssh:
    install-server: true
    authorized-keys:
      - ${ssh_key}
    allow-pw: true
  network:
    version: 2
    ethernets:
      eth0:
        match:
          driver: virtio*
        addresses:
          - ${ip}/24
        routes:
          - to: default
            via: ${gateway}
        nameservers:
          addresses:
            - 8.8.8.8
            - 8.8.4.4
  storage:
    layout:
      name: direct
  packages:
    - openssh-server
    - curl
    - git
  late-commands:
    - curtin in-target --target=/target -- systemctl enable ssh
  shutdown: reboot            # Auto-reboot into installed OS when done
  user-data:
    disable_root: true
    ssh_pwauth: true
EOF

    # Create vendor-data (required for some cloud-init versions)
    cat > "$cloud_init_dir/vendor-data" << EOF
#cloud-config
EOF

    # Generate ISO
    echo "    → Creating cloud-init ISO: $iso..."
    genisoimage -output "$iso" -volid cidata -joliet -rock \
        "$cloud_init_dir/user-data" "$cloud_init_dir/meta-data" \
        "$cloud_init_dir/vendor-data" 2>/dev/null
}

# Ensure cloud-init ISO exists
ensure_cloud_init_iso() {
    local iso="${1:-$VM_CLOUD_INIT_FILE}"

    if [[ ! -f "$iso" ]]; then
        echo "  ✗ Cloud-init ISO missing"
        create_cloud_init_iso "$iso" "$VM_NAME" "$VM_IP" "$VM_USER"
        echo "  ✓ Cloud-init ISO created"
    fi
}

# Ensure all storage files exist
ensure_storage_ready() {
    local needs_fix=0

    # Check what's missing
    if ! check_disk_exists "$VM_DISK_FILE"; then
        needs_fix=1
    fi
    if ! check_uefi_vars "$VM_VARS_FILE"; then
        needs_fix=1
    fi
    if ! check_uefi_rom "$VM_EFI_ROM"; then
        needs_fix=1
    fi
    if ! check_cloud_init_iso "$VM_CLOUD_INIT_FILE"; then
        needs_fix=1
    fi

    if [[ $needs_fix -eq 1 ]]; then
        echo "  ✗ Storage needs setup"
        ensure_storage_dir
        ensure_disk_exists "$VM_DISK_FILE" "$VM_DISK_SIZE"
        ensure_uefi_vars "$VM_VARS_FILE"
        ensure_uefi_rom "$VM_EFI_ROM"
        ensure_cloud_init_iso "$VM_CLOUD_INIT_FILE"
        echo "  ✓ Storage ready"
    else
        echo "  ✓ Storage OK"
    fi
}

# Show storage status
show_storage_status() {
    echo "Storage ($STORAGE_DIR)"

    # Disk image
    if check_disk_exists "$VM_DISK_FILE"; then
        local disk_size
        disk_size=$(du -h "$VM_DISK_FILE" 2>/dev/null | cut -f1)
        local has_os=""
        if check_disk_has_os "$VM_DISK_FILE"; then
            has_os=", has partitions"
        fi
        print_check 1 "Disk image: $(basename "$VM_DISK_FILE")" "${disk_size}${has_os}"
    else
        print_check 0 "Disk image: $(basename "$VM_DISK_FILE")" "missing"
    fi

    # UEFI vars
    if check_uefi_vars "$VM_VARS_FILE"; then
        print_check 1 "UEFI vars: $(basename "$VM_VARS_FILE")" "64M"
    else
        print_check 0 "UEFI vars: $(basename "$VM_VARS_FILE")" "missing or wrong size"
    fi

    # UEFI ROM
    if check_uefi_rom "$VM_EFI_ROM"; then
        print_check 1 "UEFI ROM: $(basename "$VM_EFI_ROM")" "64M"
    else
        print_check 0 "UEFI ROM: $(basename "$VM_EFI_ROM")" "missing or wrong size"
    fi

    # Ubuntu ISO
    local iso
    iso=$(get_ubuntu_iso)
    if [[ -n "$iso" ]] && check_ubuntu_iso; then
        local iso_size
        iso_size=$(numfmt --to=iec "$(stat -c%s "$iso")" 2>/dev/null)
        print_check 1 "Ubuntu ISO: $(basename "$iso")" "$iso_size"
    else
        print_check 0 "Ubuntu ISO" "missing or incomplete"
    fi

    # Cloud-init ISO
    if check_cloud_init_iso "$VM_CLOUD_INIT_FILE"; then
        local ci_size
        ci_size=$(du -h "$VM_CLOUD_INIT_FILE" 2>/dev/null | cut -f1)
        print_check 1 "Cloud-init: $(basename "$VM_CLOUD_INIT_FILE")" "$ci_size"
    else
        print_check 0 "Cloud-init: $(basename "$VM_CLOUD_INIT_FILE")" "missing"
    fi
}

# Remove all VM storage files
remove_storage() {
    local name="${1:-$VM_NAME}"

    echo "Removing storage for VM '$name'..."

    [[ -f "$VM_DISK_FILE" ]] && rm -f "$VM_DISK_FILE" && echo "  Removed: $VM_DISK_FILE"
    [[ -f "$VM_VARS_FILE" ]] && rm -f "$VM_VARS_FILE" && echo "  Removed: $VM_VARS_FILE"
    [[ -f "$VM_EFI_ROM" ]] && rm -f "$VM_EFI_ROM" && echo "  Removed: $VM_EFI_ROM"
    [[ -f "$VM_CLOUD_INIT_FILE" ]] && rm -f "$VM_CLOUD_INIT_FILE" && echo "  Removed: $VM_CLOUD_INIT_FILE"
    [[ -f "$VM_PID_FILE" ]] && rm -f "$VM_PID_FILE"
    [[ -f "$VM_LOG_FILE" ]] && rm -f "$VM_LOG_FILE"
}
