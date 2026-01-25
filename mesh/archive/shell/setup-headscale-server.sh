#!/bin/bash
# Headscale Server Setup
# Self-hosted Tailscale coordination server for sfspark1 (GB10)
#
# This script installs and configures Headscale on the local machine,
# which acts as the coordination server for the mesh network.
# No external dependencies on tailscale.com.
#
# Usage:
#   sudo ./setup-headscale-server.sh              # Install and configure
#   sudo ./setup-headscale-server.sh --keygen     # Generate new pre-auth key
#   sudo ./setup-headscale-server.sh --status     # Show server status
#
# EXIT CODES:
#   0 - Success
#   1 - General error
#   2 - Prerequisites not met

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/mesh-common.sh"

# Headscale configuration
HEADSCALE_VERSION="0.23.0"
HEADSCALE_USER="mesh"
HEADSCALE_PORT="8080"
HEADSCALE_CONFIG_DIR="/etc/headscale"
HEADSCALE_DATA_DIR="/var/lib/headscale"

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

ACTION="setup"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keygen|-k)
            ACTION="keygen"
            shift
            ;;
        --status|-s)
            ACTION="status"
            shift
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --keygen, -k   Generate new pre-auth key for clients"
            echo "  --status, -s   Show Headscale server status"
            echo "  --help, -h     Show this help"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit $EXIT_PREREQ
    fi
}

check_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64)
            HEADSCALE_ARCH="arm64"
            ;;
        x86_64)
            HEADSCALE_ARCH="amd64"
            ;;
        *)
            error "Unsupported architecture: $arch"
            exit $EXIT_PREREQ
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Installation
# ─────────────────────────────────────────────────────────────────────────────

install_headscale() {
    if command -v headscale &>/dev/null; then
        ok "Headscale already installed: $(headscale version 2>/dev/null || echo 'unknown')"
        return 0
    fi

    info "Installing Headscale v${HEADSCALE_VERSION} for ${HEADSCALE_ARCH}..."

    local download_url="https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_${HEADSCALE_ARCH}"

    curl -fsSL "$download_url" -o /tmp/headscale
    chmod +x /tmp/headscale
    mv /tmp/headscale /usr/local/bin/headscale

    ok "Headscale installed to /usr/local/bin/headscale"
}

create_config() {
    if [[ -f "$HEADSCALE_CONFIG_DIR/config.yaml" ]]; then
        ok "Headscale config already exists"
        return 0
    fi

    info "Creating Headscale configuration..."

    mkdir -p "$HEADSCALE_CONFIG_DIR"
    mkdir -p "$HEADSCALE_DATA_DIR"

    # Get local IP for server URL
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    cat > "$HEADSCALE_CONFIG_DIR/config.yaml" << EOF
# Headscale configuration for mesh network
# Server: sfspark1 (GB10)

server_url: http://${server_ip}:${HEADSCALE_PORT}
listen_addr: 0.0.0.0:${HEADSCALE_PORT}
metrics_listen_addr: 127.0.0.1:9090

grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false

private_key_path: ${HEADSCALE_DATA_DIR}/private.key
noise:
  private_key_path: ${HEADSCALE_DATA_DIR}/noise_private.key

# Use embedded SQLite
database:
  type: sqlite
  sqlite:
    path: ${HEADSCALE_DATA_DIR}/db.sqlite

# IP allocation for mesh network
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

# DERP (relay) - use Tailscale's public relays
# These are only used when direct connections fail
derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  auto_update_enabled: true
  update_frequency: 24h

# Disable external OIDC - use pre-auth keys
oidc:

# DNS configuration (MagicDNS equivalent)
dns:
  override_local_dns: false
  nameservers:
    global:
      - 1.1.1.1
      - 8.8.8.8
  magic_dns: true
  base_domain: mesh.local

# Logging
log:
  format: text
  level: info

# ACL policy file (optional, allow all by default)
acl_policy_path: ""

# Unix socket for CLI
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"

# Node expiry (0 = never)
ephemeral_node_inactivity_timeout: 30m

# Enable node auto-approval for our namespace
policy:
  mode: file
EOF

    ok "Configuration created at $HEADSCALE_CONFIG_DIR/config.yaml"
}

create_systemd_service() {
    if [[ -f /etc/systemd/system/headscale.service ]]; then
        ok "Headscale systemd service already exists"
        return 0
    fi

    info "Creating systemd service..."

    cat > /etc/systemd/system/headscale.service << EOF
[Unit]
Description=Headscale - Self-hosted Tailscale control server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/headscale serve
Restart=always
RestartSec=5

# Create socket directory
ExecStartPre=/bin/mkdir -p /var/run/headscale

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ok "Systemd service created"
}

create_user_namespace() {
    # Check if user/namespace exists
    if headscale users list 2>/dev/null | grep -q "$HEADSCALE_USER"; then
        ok "User '$HEADSCALE_USER' already exists"
        return 0
    fi

    info "Creating user namespace '$HEADSCALE_USER'..."
    headscale users create "$HEADSCALE_USER"
    ok "User '$HEADSCALE_USER' created"
}

start_service() {
    info "Starting Headscale service..."

    systemctl enable headscale
    systemctl start headscale

    # Wait for service to be ready
    sleep 2

    if systemctl is-active --quiet headscale; then
        ok "Headscale service running"
    else
        error "Headscale service failed to start"
        journalctl -u headscale -n 20 --no-pager
        exit $EXIT_ERROR
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-auth key generation
# ─────────────────────────────────────────────────────────────────────────────

generate_preauth_key() {
    section "Generate Pre-Auth Key"
    echo ""

    if ! systemctl is-active --quiet headscale; then
        error "Headscale service is not running"
        echo "  Start with: sudo systemctl start headscale"
        exit $EXIT_ERROR
    fi

    info "Generating pre-auth key for user '$HEADSCALE_USER'..."

    # Generate key that's reusable and doesn't expire (for mesh setup)
    local key
    key=$(headscale preauthkeys create --user "$HEADSCALE_USER" --reusable --expiration 24h 2>&1 | tail -1)

    echo ""
    echo "Pre-Auth Key (valid 24h, reusable):"
    echo ""
    echo "  $key"
    echo ""
    echo "Use this key on client machines:"
    echo ""
    echo "  ./setup-mesh.sh --key $key"
    echo ""

    # Save to file for convenience
    echo "$key" > "$HEADSCALE_DATA_DIR/current-preauth-key"
    chmod 600 "$HEADSCALE_DATA_DIR/current-preauth-key"
    info "Key also saved to: $HEADSCALE_DATA_DIR/current-preauth-key"
}

# ─────────────────────────────────────────────────────────────────────────────
# Status
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    section "Headscale Server Status"
    echo ""

    # Service status
    if systemctl is-active --quiet headscale; then
        ok "Service: running"
    else
        error "Service: stopped"
        echo "  Start with: sudo systemctl start headscale"
    fi

    # Server URL
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    echo "  Server URL: http://${server_ip}:${HEADSCALE_PORT}"

    # Connected nodes
    echo ""
    info "Connected nodes:"
    headscale nodes list 2>/dev/null || echo "  (none)"

    # Pre-auth keys
    echo ""
    info "Active pre-auth keys:"
    headscale preauthkeys list --user "$HEADSCALE_USER" 2>/dev/null || echo "  (none)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main setup
# ─────────────────────────────────────────────────────────────────────────────

main_setup() {
    section "Headscale Server Setup"
    echo ""

    detect_environment
    print_environment
    echo ""

    # Verify we're on sfspark1
    if [[ "$ENV_ROLE" != "sfspark1" ]]; then
        warn "This script is designed for sfspark1 (the mesh coordinator)"
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
    fi

    check_root
    check_architecture

    if ! require_commands curl; then
        error "curl is required"
        exit $EXIT_PREREQ
    fi

    step_init 6

    step "Installing Headscale"
    install_headscale

    step "Creating configuration"
    create_config

    step "Creating systemd service"
    create_systemd_service

    step "Starting Headscale service"
    start_service

    step "Creating user namespace"
    create_user_namespace

    step "Generating initial pre-auth key"
    generate_preauth_key

    # Summary
    section "Setup Complete"
    echo ""
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo "Headscale server is running at: http://${server_ip}:${HEADSCALE_PORT}"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Note the pre-auth key shown above"
    echo ""
    echo "  2. On client machines (WSL2, Windows), run:"
    echo "     ./setup-mesh.sh --server http://${server_ip}:${HEADSCALE_PORT} --key <KEY>"
    echo ""
    echo "  3. To generate a new key later:"
    echo "     sudo $0 --keygen"
    echo ""
    echo "  4. To check status:"
    echo "     sudo $0 --status"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

case "$ACTION" in
    setup)  main_setup ;;
    keygen) check_root; generate_preauth_key ;;
    status) show_status ;;
esac
