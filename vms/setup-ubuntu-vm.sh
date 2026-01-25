#!/bin/bash
# Ubuntu 24.04 Server ARM64 VM Setup Script
# Run with sudo: sudo ./setup-ubuntu-vm.sh
#
# This sets up Ubuntu to share networking with the existing Windows VM
# using a bridge (br-vm) that both VMs' TAP interfaces connect to.

set -e

STORAGE_DIR="/storage"
VM_NAME="ubuntu"
DISK_SIZE="64G"

ISO_URL="https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.3-live-server-arm64.iso"
ISO_FILE="${STORAGE_DIR}/ubuntu-24.04.3-server-arm64.iso"
DISK_FILE="${STORAGE_DIR}/${VM_NAME}.img"
VARS_FILE="${STORAGE_DIR}/${VM_NAME}.vars"
UEFI_ROM="${STORAGE_DIR}/windows.rom"
CLOUD_INIT_ISO="${STORAGE_DIR}/ubuntu-cloud-init.iso"

# Networking: Bridge for VM-to-VM communication
BRIDGE_NAME="br-vm"
UBUNTU_TAP="tap-ubuntu"
WINDOWS_TAP="qemu"  # Existing Windows VM TAP

# NAT subnet for VMs
VM_SUBNET="192.168.50"
HOST_IP="${VM_SUBNET}.1"
VM_IP="${VM_SUBNET}.10"
UPSTREAM_IF="enP7s7"

# VM identity for autoinstall
VM_HOSTNAME="ubu1"
VM_USER="steve"
# Get SSH key from the user running sudo (not root)
SSH_KEY_FILE="/home/${SUDO_USER:-$VM_USER}/.ssh/id_ed25519.pub"
if [[ ! -f "$SSH_KEY_FILE" ]]; then
    SSH_KEY_FILE="/home/${SUDO_USER:-$VM_USER}/.ssh/id_rsa.pub"
fi

echo "=== Ubuntu 24.04 Server VM Setup ==="
echo ""

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

# Step 0: Ensure storage directory exists
echo "[0/8] Checking storage directory..."
if [[ ! -d "$STORAGE_DIR" ]]; then
    echo "  Creating $STORAGE_DIR..."
    mkdir -p "$STORAGE_DIR"
    chmod 755 "$STORAGE_DIR"
else
    echo "  $STORAGE_DIR exists"
fi

# Step 1: Check/install QEMU and UEFI firmware
echo "[1/8] Checking QEMU and UEFI firmware..."
NEED_INSTALL=""
if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "  qemu-system-arm not installed"
    NEED_INSTALL="qemu-system-arm"
fi
if ! [[ -f "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" ]]; then
    echo "  qemu-efi-aarch64 not installed"
    NEED_INSTALL="$NEED_INSTALL qemu-efi-aarch64"
fi
if [[ -n "$NEED_INSTALL" ]]; then
    echo "  Installing:$NEED_INSTALL"
    apt-get update && apt-get install -y $NEED_INSTALL
fi

# UEFI ROM must be 64MB for pflash. Create padded version if needed.
UEFI_ROM="${STORAGE_DIR}/ubuntu-efi.rom"
UEFI_SIZE_NEEDED=67108864  # 64MB
if [[ -f "$UEFI_ROM" ]]; then
    ROM_SIZE=$(stat -c%s "$UEFI_ROM" 2>/dev/null || echo 0)
    if [[ $ROM_SIZE -eq $UEFI_SIZE_NEEDED ]]; then
        echo "  UEFI ROM exists: $UEFI_ROM (64MB)"
    else
        echo "  UEFI ROM wrong size, recreating..."
        rm -f "$UEFI_ROM"
    fi
fi
if [[ ! -f "$UEFI_ROM" ]]; then
    echo "  Creating 64MB UEFI ROM (padded from system QEMU_EFI.fd)..."
    # Create 64MB file, copy UEFI to start
    truncate -s 64M "$UEFI_ROM"
    dd if=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd of="$UEFI_ROM" conv=notrunc 2>/dev/null
fi
# Export for start script
echo "$UEFI_ROM" > "${STORAGE_DIR}/.ubuntu-uefi-rom-path"

# Step 2: Download ISO
echo "[2/8] Checking Ubuntu ISO..."
if [[ -f "$ISO_FILE" ]]; then
    # Check if file looks complete (>2GB for server ISO)
    ISO_SIZE=$(stat -c%s "$ISO_FILE" 2>/dev/null || echo 0)
    if [[ $ISO_SIZE -gt 2000000000 ]]; then
        echo "  ISO exists: $ISO_FILE ($(numfmt --to=iec $ISO_SIZE))"
    else
        echo "  ISO incomplete ($(numfmt --to=iec $ISO_SIZE)), resuming download..."
        wget -c -O "$ISO_FILE" "$ISO_URL"
    fi
else
    echo "  Downloading Ubuntu 24.04 Server ARM64..."
    wget -c -O "$ISO_FILE" "$ISO_URL"
fi

# Step 3: Create disk image
echo "[3/8] Checking disk image..."
if [[ ! -f "$DISK_FILE" ]]; then
    echo "  Creating ${DISK_SIZE} raw disk..."
    qemu-img create -f raw "$DISK_FILE" "$DISK_SIZE"
else
    echo "  Disk exists: $DISK_FILE ($(du -h "$DISK_FILE" | cut -f1))"
fi

# Step 4: Create UEFI vars (must be 64MB to match QEMU pflash requirements)
echo "[4/8] Checking UEFI vars..."
VARS_SIZE_NEEDED=67108864  # 64MB
if [[ -f "$VARS_FILE" ]]; then
    VARS_SIZE=$(stat -c%s "$VARS_FILE" 2>/dev/null || echo 0)
    if [[ $VARS_SIZE -lt $VARS_SIZE_NEEDED ]]; then
        echo "  UEFI vars too small ($VARS_SIZE bytes), recreating..."
        truncate -s 64M "$VARS_FILE"
    else
        echo "  UEFI vars exists: $VARS_FILE"
    fi
else
    echo "  Creating UEFI vars file (64MB)..."
    truncate -s 64M "$VARS_FILE"
fi

# Step 5: Create cloud-init ISO for automated installation
echo "[5/8] Creating cloud-init autoinstall ISO..."
if ! command -v genisoimage &>/dev/null; then
    echo "  Installing genisoimage..."
    apt-get update && apt-get install -y genisoimage
fi

# Read SSH public key
if [[ -f "$SSH_KEY_FILE" ]]; then
    SSH_PUBLIC_KEY=$(cat "$SSH_KEY_FILE")
    echo "  Using SSH key: ${SSH_KEY_FILE}"
else
    echo "  Warning: No SSH key found at $SSH_KEY_FILE"
    echo "  You'll need to set up SSH manually after install"
    SSH_PUBLIC_KEY=""
fi

# Create cloud-init directory
CLOUD_INIT_DIR=$(mktemp -d)
trap "rm -rf $CLOUD_INIT_DIR" EXIT

# Create meta-data
cat > "$CLOUD_INIT_DIR/meta-data" << EOF
instance-id: ${VM_HOSTNAME}
local-hostname: ${VM_HOSTNAME}
EOF

# Create user-data with autoinstall
cat > "$CLOUD_INIT_DIR/user-data" << EOF
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ${VM_HOSTNAME}
    username: ${VM_USER}
    # Password: ubuntu (change on first login recommended)
    password: '\$6\$rounds=4096\$xyz\$JXKZ7kQvJxK9zvPQ8dNxPJqwPqrP4tZR8mzMJGvMmLG9Q5LXZ.oPzIr.jFQmj7mPz3YQE2qQs/KGNyB5YwNjH.'
  ssh:
    install-server: true
    authorized-keys:
      - ${SSH_PUBLIC_KEY}
    allow-pw: true
  network:
    version: 2
    ethernets:
      enp0s1:
        addresses:
          - ${VM_IP}/24
        routes:
          - to: default
            via: ${HOST_IP}
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
  user-data:
    disable_root: true
    ssh_pwauth: true
EOF

# Generate ISO
genisoimage -output "$CLOUD_INIT_ISO" -volid cidata -joliet -rock \
    "$CLOUD_INIT_DIR/user-data" "$CLOUD_INIT_DIR/meta-data" 2>/dev/null
echo "  Created: $CLOUD_INIT_ISO"

# Step 6: Create bridge
echo "[6/8] Setting up network bridge..."
if ! ip link show "$BRIDGE_NAME" &>/dev/null; then
    echo "  Creating bridge $BRIDGE_NAME..."
    ip link add name "$BRIDGE_NAME" type bridge
fi
# Ensure bridge has correct IP (idempotent)
if ! ip addr show "$BRIDGE_NAME" 2>/dev/null | grep -q "${HOST_IP}/"; then
    echo "  Assigning ${HOST_IP}/24 to $BRIDGE_NAME..."
    ip addr add "${HOST_IP}/24" dev "$BRIDGE_NAME" 2>/dev/null || true
fi
# Ensure bridge is up
ip link set "$BRIDGE_NAME" up 2>/dev/null || true
echo "  Bridge $BRIDGE_NAME ready"

# Step 7: Enable NAT
echo "[7/8] Configuring NAT..."
echo 1 | tee /proc/sys/net/ipv4/ip_forward >/dev/null

# Add NAT rules (idempotent with -C check)
if ! iptables -t nat -C POSTROUTING -s "${VM_SUBNET}.0/24" -o "$UPSTREAM_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "${VM_SUBNET}.0/24" -o "$UPSTREAM_IF" -j MASQUERADE
    echo "  Added NAT masquerade rule"
fi
if ! iptables -C FORWARD -i "$BRIDGE_NAME" -o "$UPSTREAM_IF" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "$BRIDGE_NAME" -o "$UPSTREAM_IF" -j ACCEPT
    echo "  Added FORWARD rule (outbound)"
fi
if ! iptables -C FORWARD -i "$UPSTREAM_IF" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "$UPSTREAM_IF" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo "  Added FORWARD rule (inbound established)"
fi

# Step 8: Create Ubuntu TAP
echo "[8/8] Setting up TAP interfaces..."
if ! ip link show "$UBUNTU_TAP" &>/dev/null; then
    ip tuntap add dev "$UBUNTU_TAP" mode tap
    ip link set "$UBUNTU_TAP" master "$BRIDGE_NAME"
    ip link set "$UBUNTU_TAP" up
    echo "  Created $UBUNTU_TAP"
else
    echo "  $UBUNTU_TAP exists"
fi

# Attach Windows TAP to bridge if it exists and isn't already bridged
if ip link show "$WINDOWS_TAP" &>/dev/null; then
    if ! ip link show "$WINDOWS_TAP" | grep -q "master $BRIDGE_NAME"; then
        echo "  Attaching Windows TAP ($WINDOWS_TAP) to bridge..."
        ip link set "$WINDOWS_TAP" master "$BRIDGE_NAME"
    else
        echo "  Windows TAP already on bridge"
    fi
else
    echo "  Note: Windows TAP ($WINDOWS_TAP) not found - Windows VM may need restart"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Storage:"
ls -lh "$DISK_FILE" "$VARS_FILE" "$ISO_FILE" 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
echo ""
echo "Network:"
echo "  Bridge:     $BRIDGE_NAME (${HOST_IP}/24)"
echo "  Ubuntu TAP: $UBUNTU_TAP"
echo "  Windows:    $WINDOWS_TAP (attach after Windows VM restart)"
echo ""
echo "VM IP assignment (configure in guest or use DHCP server):"
echo "  Gateway:    $HOST_IP"
echo "  Ubuntu:     ${VM_SUBNET}.10 (suggested)"
echo "  Windows:    ${VM_SUBNET}.11 (suggested)"
echo ""
echo "Next: sudo ./start-ubuntu-vm.sh install"
