#!/bin/bash
# VM Network Management
# Bridge, TAP, NAT configuration

BRIDGE_NAME="${BRIDGE_NAME:-br-vm}"
VM_SUBNET="${VM_SUBNET:-192.168.50}"
HOST_IP="${HOST_IP:-${VM_SUBNET}.1}"

# Create bridge if it doesn't exist
ensure_bridge() {
    local bridge="${1:-$BRIDGE_NAME}"
    local host_ip="${2:-$HOST_IP}"

    if ! ip link show "$bridge" &>/dev/null; then
        echo "    → Creating bridge $bridge..."
        ip link add name "$bridge" type bridge
    fi

    if ! ip addr show "$bridge" 2>/dev/null | grep -q "${host_ip}/"; then
        echo "    → Adding IP ${host_ip}/24 to $bridge..."
        ip addr add "${host_ip}/24" dev "$bridge" 2>/dev/null || true
    fi

    if ! ip link show "$bridge" 2>/dev/null | grep -q "state UP"; then
        echo "    → Bringing up $bridge..."
        ip link set "$bridge" up
    fi
}

# Create TAP interface and attach to bridge
ensure_tap() {
    local tap="${1:-$VM_TAP_NAME}"
    local bridge="${2:-$BRIDGE_NAME}"

    if ! ip link show "$tap" &>/dev/null; then
        echo "    → Creating TAP $tap..."
        ip tuntap add dev "$tap" mode tap
    fi

    if ! ip link show "$tap" 2>/dev/null | grep -q "master ${bridge}"; then
        echo "    → Attaching $tap to $bridge..."
        ip link set "$tap" master "$bridge"
    fi

    if ! ip link show "$tap" 2>/dev/null | grep -q "state UP\|state UNKNOWN"; then
        echo "    → Bringing up $tap..."
        ip link set "$tap" up
    fi
}

# Enable IP forwarding
ensure_ip_forwarding() {
    if [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) != "1" ]]; then
        echo "    → Enabling IP forwarding..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
    fi
}

# Configure NAT masquerade rule
ensure_nat_masquerade() {
    local upstream="${1:-$(detect_upstream_interface)}"
    local subnet="${2:-${VM_SUBNET}.0/24}"

    if ! iptables -t nat -C POSTROUTING -s "$subnet" -o "$upstream" -j MASQUERADE 2>/dev/null; then
        echo "    → Adding NAT masquerade rule (via $upstream)..."
        iptables -t nat -A POSTROUTING -s "$subnet" -o "$upstream" -j MASQUERADE
    fi
}

# Configure forward rules for bridge
ensure_forward_rules() {
    local bridge="${1:-$BRIDGE_NAME}"
    local upstream="${2:-$(detect_upstream_interface)}"

    if ! iptables -C FORWARD -i "$bridge" -o "$upstream" -j ACCEPT 2>/dev/null; then
        echo "    → Adding FORWARD rule (outbound)..."
        iptables -A FORWARD -i "$bridge" -o "$upstream" -j ACCEPT
    fi

    if ! iptables -C FORWARD -i "$upstream" -o "$bridge" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        echo "    → Adding FORWARD rule (inbound established)..."
        iptables -A FORWARD -i "$upstream" -o "$bridge" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi
}

# Ensure all network infrastructure is ready
ensure_network_ready() {
    local tap="${1:-$VM_TAP_NAME}"
    local bridge="${2:-$BRIDGE_NAME}"
    local upstream
    upstream=$(detect_upstream_interface)

    local needs_fix=0

    # Check what's missing
    if ! check_bridge_exists "$bridge" || \
       ! check_bridge_has_ip "$bridge" "$HOST_IP" || \
       ! check_bridge_up "$bridge"; then
        needs_fix=1
    fi

    if ! check_tap_exists "$tap" || \
       ! check_tap_on_bridge "$tap" "$bridge" || \
       ! check_tap_up "$tap"; then
        needs_fix=1
    fi

    if ! check_ip_forwarding || \
       ! check_nat_rule "$upstream" || \
       ! check_forward_rules "$bridge" "$upstream"; then
        needs_fix=1
    fi

    if [[ $needs_fix -eq 1 ]]; then
        echo "  ✗ Network needs setup"
        ensure_bridge "$bridge" "$HOST_IP"
        ensure_tap "$tap" "$bridge"
        ensure_ip_forwarding
        ensure_nat_masquerade "$upstream"
        ensure_forward_rules "$bridge" "$upstream"
        echo "  ✓ Network ready"
    else
        echo "  ✓ Network OK"
    fi
}

# Remove TAP interface
remove_tap() {
    local tap="${1:-$VM_TAP_NAME}"

    if ip link show "$tap" &>/dev/null; then
        ip link set "$tap" down 2>/dev/null || true
        ip link delete "$tap" 2>/dev/null || true
    fi
}

# Show network status
show_network_status() {
    local tap="${1:-$VM_TAP_NAME}"
    local bridge="${2:-$BRIDGE_NAME}"
    local upstream
    upstream=$(detect_upstream_interface)

    echo "Network"

    # Bridge status
    if check_bridge_exists "$bridge"; then
        local bridge_ip
        bridge_ip=$(ip addr show "$bridge" 2>/dev/null | grep -oP 'inet \K[0-9./]+' | head -1)
        local bridge_state
        bridge_state=$(ip link show "$bridge" 2>/dev/null | grep -oP 'state \K\w+')
        print_check 1 "Bridge $bridge: ${bridge_ip:-no IP} ($bridge_state)"
    else
        print_check 0 "Bridge $bridge: missing"
    fi

    # TAP status
    if check_tap_exists "$tap"; then
        local tap_master
        tap_master=$(ip link show "$tap" 2>/dev/null | grep -oP 'master \K\w+')
        local tap_state
        tap_state=$(ip link show "$tap" 2>/dev/null | grep -oP 'state \K\w+')
        print_check 1 "TAP $tap: attached to ${tap_master:-none} ($tap_state)"
    else
        print_check 0 "TAP $tap: missing"
    fi

    # NAT rules (requires root to check iptables)
    if [[ $EUID -eq 0 ]]; then
        if check_nat_rule "$upstream" && check_forward_rules "$bridge" "$upstream"; then
            print_check 1 "NAT rules configured" "via $upstream"
        else
            print_check 0 "NAT rules incomplete"
        fi
    else
        print_check 1 "NAT rules" "run as root to verify"
    fi

    # IP forwarding
    print_check "$(check_ip_forwarding && echo 1 || echo 0)" "IP forwarding enabled"
}
