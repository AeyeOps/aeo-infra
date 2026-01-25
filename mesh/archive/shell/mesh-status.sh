#!/bin/bash
# Mesh Network Status
# Health check and diagnostics for Headscale + Syncthing mesh network
#
# Usage:
#   ./mesh-status.sh           # Quick status check
#   ./mesh-status.sh --verbose # Detailed diagnostics
#
# EXIT CODES:
#   0 - All healthy (or diagnostics complete in verbose mode)
#   1 - Issues detected

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/mesh-common.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v   Detailed diagnostics with fixes"
            echo "  --help, -h      Show this help"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Track issues
ISSUES=0

# Verbose-mode helpers
check_pass() { echo "  ${GREEN}[PASS]${RESET} $*"; }
check_fail() { echo "  ${RED}[FAIL]${RESET} $*"; ((ISSUES++)) || true; }
check_warn() { echo "  ${YELLOW}[WARN]${RESET} $*"; }
check_info() { echo "  ${BLUE}[INFO]${RESET} $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# Environment
# ─────────────────────────────────────────────────────────────────────────────

show_environment() {
    section "Environment"
    detect_environment

    if $VERBOSE; then
        check_info "Hostname: $ENV_HOSTNAME"
        check_info "OS Type: $ENV_TYPE"
        check_info "Role: $ENV_ROLE"
        check_info "System: $(uname -a | cut -c1-60)..."

        # Check required commands
        echo ""
        for cmd in curl ssh tailscale; do
            if command -v $cmd &>/dev/null; then
                check_pass "$cmd available"
            else
                check_fail "$cmd not found"
            fi
        done

        # WSL2-specific
        if [[ "$ENV_TYPE" == "wsl2" ]]; then
            echo ""
            check_info "WSL2 Checks:"
            if has_systemd; then
                check_pass "systemd enabled"
            else
                check_fail "systemd not enabled"
                echo "         Fix: Add [boot] systemd=true to /etc/wsl.conf"
            fi
        fi
    else
        print_environment
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Headscale Server Status (sfspark1 only)
# ─────────────────────────────────────────────────────────────────────────────

show_headscale_server() {
    if [[ "$ENV_ROLE" != "sfspark1" ]]; then
        return
    fi

    section "Headscale Server"

    if ! command -v headscale &>/dev/null; then
        if $VERBOSE; then
            check_fail "Headscale not installed"
            echo "         Fix: sudo ./setup-headscale-server.sh"
        else
            warn "Headscale not installed"
            ((ISSUES++)) || true
        fi
        return
    fi

    if systemctl is-active --quiet headscale 2>/dev/null; then
        if $VERBOSE; then
            check_pass "Headscale service running"
            echo ""
            check_info "Connected nodes:"
            headscale nodes list 2>/dev/null | head -10 || echo "    (none)"
        else
            ok "Headscale service running"
            local node_count
            node_count=$(headscale nodes list 2>/dev/null | grep -c "online" || echo "0")
            echo "  Connected nodes: $node_count"
        fi
    else
        if $VERBOSE; then
            check_fail "Headscale service not running"
            echo "         Fix: sudo systemctl start headscale"
        else
            warn "Headscale service not running"
            ((ISSUES++)) || true
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Tailscale Client Status
# ─────────────────────────────────────────────────────────────────────────────

show_tailscale() {
    section "Tailscale (Mesh VPN)"

    local server_url
    server_url=$(get_headscale_server)
    echo "  Headscale Server: $server_url"

    if ! command -v tailscale &>/dev/null; then
        if $VERBOSE; then
            check_fail "Tailscale not installed"
            echo "         Fix: $SCRIPT_DIR/setup-mesh.sh --server $server_url --key KEY"
        else
            warn "Tailscale not installed"
            ((ISSUES++)) || true
        fi
        return
    fi

    if tailscale_connected; then
        if $VERBOSE; then
            check_pass "Tailscale connected"
            echo ""
            tailscale status | head -10
            echo ""
            local ts_ip
            ts_ip=$(get_tailscale_ip)
            check_info "Tailscale IP: $ts_ip"
        else
            ok "Tailscale connected"
            local ts_ip
            ts_ip=$(get_tailscale_ip)
            echo "  Tailscale IP: $ts_ip"
            tailscale status 2>/dev/null | head -5
        fi
    else
        if $VERBOSE; then
            check_fail "Tailscale not connected"
            echo "         Fix: $SCRIPT_DIR/setup-mesh.sh --join --server $server_url --key KEY"
        else
            warn "Tailscale not connected"
            ((ISSUES++)) || true
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Syncthing Status
# ─────────────────────────────────────────────────────────────────────────────

show_syncthing() {
    section "Syncthing"

    local ST_PORT ST_CONFIG_DIR
    ST_PORT=$(get_syncthing_port)
    ST_CONFIG_DIR=$(get_syncthing_config_dir)

    echo "  GUI: http://localhost:$ST_PORT"

    if ! syncthing_running; then
        if $VERBOSE; then
            check_fail "Syncthing not running on port $ST_PORT"
            if has_systemd; then
                echo "         Fix: systemctl --user start syncthing"
            else
                echo "         Fix: syncthing &"
            fi
        else
            warn "Syncthing not running"
            ((ISSUES++)) || true
        fi
        return
    fi

    if $VERBOSE; then
        check_pass "Syncthing running on port $ST_PORT"
    else
        ok "Syncthing running on port $ST_PORT"
    fi

    # Get API key for details
    local API_KEY
    API_KEY=$(get_syncthing_api_key 2>/dev/null) || return

    # Device ID
    local MY_ID
    MY_ID=$(curl -s -H "X-API-Key: $API_KEY" \
        "http://localhost:$ST_PORT/rest/system/status" 2>/dev/null | \
        grep -oP '"myID"\s*:\s*"\K[^"]+' || echo "unknown")
    echo "  Device: ${MY_ID:0:7}..."

    # Connections
    local CONNECTIONS
    CONNECTIONS=$(curl -s -H "X-API-Key: $API_KEY" \
        "http://localhost:$ST_PORT/rest/system/connections" 2>/dev/null)

    if command -v jq &>/dev/null; then
        local CONNECTED
        CONNECTED=$(echo "$CONNECTIONS" | jq '[.connections | to_entries[] | select(.value.connected == true)] | length' 2>/dev/null || echo "0")
        echo "  Connected: $CONNECTED device(s)"

        if $VERBOSE; then
            echo "$CONNECTIONS" | jq -r '
                .connections | to_entries[] |
                "    \(.key[0:7])...: \(if .value.connected then "connected" else "disconnected" end)"
            ' 2>/dev/null || true
        fi
    fi

    # Folder status
    local FOLDER_STATUS
    FOLDER_STATUS=$(curl -s -H "X-API-Key: $API_KEY" \
        "http://localhost:$ST_PORT/rest/db/status?folder=opt-shared" 2>/dev/null)

    if command -v jq &>/dev/null && [[ -n "$FOLDER_STATUS" ]]; then
        local STATE NEED_FILES
        STATE=$(echo "$FOLDER_STATUS" | jq -r '.state // "unknown"' 2>/dev/null)
        NEED_FILES=$(echo "$FOLDER_STATUS" | jq -r '.needFiles // 0' 2>/dev/null)
        echo "  Folder: opt-shared ($STATE)"
        [[ "$NEED_FILES" != "0" ]] && echo "  Pending: $NEED_FILES files"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH Connectivity
# ─────────────────────────────────────────────────────────────────────────────

show_ssh() {
    section "SSH Connectivity"

    # Define mesh hosts based on current role
    declare -A SSH_HOSTS
    case "$ENV_ROLE" in
        sfspark1)
            SSH_HOSTS=(["office-one"]="office-one.local:2222" ["windows"]="office-one.local:22")
            ;;
        wsl2)
            SSH_HOSTS=(["sfspark1"]="sfspark1.local:22" ["windows"]="localhost:22")
            ;;
        windows)
            SSH_HOSTS=(["sfspark1"]="sfspark1.local:22" ["office-one"]="localhost:2222")
            ;;
        *)
            SSH_HOSTS=(["sfspark1"]="sfspark1.local:22" ["office-one"]="office-one.local:2222" ["windows"]="office-one.local:22")
            ;;
    esac

    for host in "${!SSH_HOSTS[@]}"; do
        local addr="${SSH_HOSTS[$host]}"
        local host_part="${addr%:*}"
        local port_part="${addr#*:}"

        printf "  %-12s " "$host:"

        if timeout 2 bash -c "echo >/dev/tcp/$host_part/$port_part" 2>/dev/null; then
            if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
                   -p "$port_part" "steve@$host_part" "echo OK" 2>/dev/null | grep -q OK; then
                echo "${GREEN}connected${RESET}"
            else
                echo "${YELLOW}port open, auth failed${RESET}"
                ((ISSUES++)) || true
            fi
        else
            echo "${RED}unreachable${RESET}"
            ((ISSUES++)) || true
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Verbose: Network diagnostics
# ─────────────────────────────────────────────────────────────────────────────

show_network_verbose() {
    section "Network Diagnostics"

    local LOCAL_IP
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    check_info "Local IP: ${LOCAL_IP:-unknown}"

    # Tailscale IP
    if tailscale_connected; then
        local TS_IP
        TS_IP=$(get_tailscale_ip)
        check_info "Tailscale IP: ${TS_IP:-unknown}"
    fi

    # DNS resolution
    echo ""
    check_info "DNS Resolution:"
    for host in sfspark1.local office-one.local; do
        local resolved
        resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1}')
        if [[ -n "$resolved" ]]; then
            check_pass "$host -> $resolved"
        else
            check_warn "$host not resolving"
        fi
    done

    # Headscale server reachability
    echo ""
    check_info "Headscale Server:"
    local server_url
    server_url=$(get_headscale_server)
    if curl -s --connect-timeout 3 "$server_url/health" &>/dev/null; then
        check_pass "$server_url reachable"
    else
        check_fail "$server_url unreachable"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Verbose: Common issues
# ─────────────────────────────────────────────────────────────────────────────

show_common_issues() {
    section "Common Issues"
    cat << 'EOF'

  Headscale server not running (sfspark1):
    sudo systemctl start headscale
    sudo ./setup-headscale-server.sh --status

  Tailscale not connecting:
    1. Verify Headscale server is running
    2. Get a new pre-auth key: sudo ./setup-headscale-server.sh --keygen
    3. Re-join: ./setup-mesh.sh --join --key NEW_KEY

  WSL2 SSH not accessible:
    1. Enable systemd: /etc/wsl.conf [boot] systemd=true
    2. Check port: grep Port /etc/ssh/sshd_config
    3. Windows firewall: setup-mesh.ps1 -Firewall

  Syncthing not connecting:
    1. Verify device IDs are exchanged
    2. Check firewall (ports 22000-22002)
    3. Verify folder is shared

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

if $VERBOSE; then
    section "Mesh Network Diagnostics"
else
    section "Mesh Network Status"
fi
echo ""

show_environment
show_headscale_server
show_tailscale
show_syncthing
show_ssh

if $VERBOSE; then
    show_network_verbose
    show_common_issues
fi

# Summary
section "Summary"
echo ""

if [[ $ISSUES -eq 0 ]]; then
    echo "${GREEN}${BOLD}All systems healthy${RESET}"
    exit 0
else
    echo "${YELLOW}${BOLD}$ISSUES issue(s) detected${RESET}"
    if ! $VERBOSE; then
        echo ""
        echo "Run with --verbose for detailed diagnostics"
    fi
    exit 1
fi
