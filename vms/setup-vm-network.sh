#!/bin/bash
# VM Network Setup - Creates bridge and TAP interfaces for all VMs
# Run with sudo: sudo ./setup-vm-network.sh
#
# This script should be run:
# - At system boot (via systemd service)
# - Before starting any VM
#
# Creates:
#   br-vm (192.168.50.1/24) - Bridge with NAT to upstream
#   qemu                    - TAP for Windows VM
#   tap-ubuntu              - TAP for Ubuntu VM

set -e

BRIDGE_NAME="br-vm"
VM_SUBNET="192.168.50"
HOST_IP="${VM_SUBNET}.1"
UPSTREAM_IF="enP7s7"

# TAP interfaces
TAPS=("qemu" "tap-ubuntu")

if [[ $EUID -ne 0 ]]; then
   echo "Run with sudo"
   exit 1
fi

echo "=== VM Network Setup ==="

# Create bridge if needed
if ! ip link show "$BRIDGE_NAME" &>/dev/null; then
    echo "Creating bridge $BRIDGE_NAME..."
    ip link add name "$BRIDGE_NAME" type bridge
    ip addr add "${HOST_IP}/24" dev "$BRIDGE_NAME"
    ip link set "$BRIDGE_NAME" up
else
    echo "Bridge $BRIDGE_NAME exists"
    # Ensure it's up with correct IP
    ip link set "$BRIDGE_NAME" up
    if ! ip addr show "$BRIDGE_NAME" | grep -q "$HOST_IP"; then
        ip addr add "${HOST_IP}/24" dev "$BRIDGE_NAME" 2>/dev/null || true
    fi
fi

# Create TAP interfaces
for tap in "${TAPS[@]}"; do
    if ! ip link show "$tap" &>/dev/null; then
        echo "Creating TAP $tap..."
        ip tuntap add dev "$tap" mode tap
    else
        echo "TAP $tap exists"
    fi

    # Ensure TAP is attached to bridge and up
    if ! ip link show "$tap" | grep -q "master $BRIDGE_NAME"; then
        echo "  Attaching $tap to $BRIDGE_NAME"
        ip link set "$tap" master "$BRIDGE_NAME"
    fi
    ip link set "$tap" up
done

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo 1 | tee /proc/sys/net/ipv4/ip_forward >/dev/null

# NAT rules (idempotent)
echo "Configuring NAT..."
if ! iptables -t nat -C POSTROUTING -s "${VM_SUBNET}.0/24" -o "$UPSTREAM_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "${VM_SUBNET}.0/24" -o "$UPSTREAM_IF" -j MASQUERADE
fi
if ! iptables -C FORWARD -i "$BRIDGE_NAME" -o "$UPSTREAM_IF" -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "$BRIDGE_NAME" -o "$UPSTREAM_IF" -j ACCEPT
    echo "  Added FORWARD rule (outbound)"
fi
if ! iptables -C FORWARD -i "$UPSTREAM_IF" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -A FORWARD -i "$UPSTREAM_IF" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo "  Added FORWARD rule (inbound established)"
fi

echo ""
echo "=== Network Ready ==="
ip addr show "$BRIDGE_NAME" | grep -E "inet |state"
echo ""
echo "TAP interfaces:"
for tap in "${TAPS[@]}"; do
    state=$(ip link show "$tap" | grep -oP 'state \K\w+')
    echo "  $tap: $state (master: $BRIDGE_NAME)"
done
echo ""
echo "VMs should use:"
echo "  Gateway: $HOST_IP"
echo "  Windows: ${VM_SUBNET}.11"
echo "  Ubuntu:  ${VM_SUBNET}.10"
