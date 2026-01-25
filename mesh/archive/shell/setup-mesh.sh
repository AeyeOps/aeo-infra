#!/bin/bash
# Mesh Network Client Setup
# Installs Tailscale client and connects to self-hosted Headscale server
#
# Usage:
#   ./setup-mesh.sh --server URL --key KEY   # Install and join mesh
#   ./setup-mesh.sh --join                   # Join with saved server URL
#   ./setup-mesh.sh --status                 # Show connection status
#
# The Headscale server should already be running on sfspark1.
# Get a pre-auth key with: sudo ./setup-headscale-server.sh --keygen
#
# SAFETY:
#   - Idempotent: safe to run multiple times
#   - Never deletes existing files or configurations
#
# EXIT CODES:
#   0 - Success
#   1 - General error
#   2 - Prerequisites not met

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/mesh-common.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

ACTION="setup"
HEADSCALE_SERVER=""
PREAUTH_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server|-s)
            HEADSCALE_SERVER="$2"
            shift 2
            ;;
        --key|-k)
            PREAUTH_KEY="$2"
            shift 2
            ;;
        --join|-j)
            ACTION="join"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --server, -s URL   Headscale server URL (e.g., http://sfspark1.local:8080)"
            echo "  --key, -k KEY      Pre-auth key from Headscale server"
            echo "  --join, -j         Join mesh using saved server URL"
            echo "  --status           Show connection status"
            echo "  --help, -h         Show this help"
            echo ""
            echo "Examples:"
            echo "  # First time setup (get key from: sudo ./setup-headscale-server.sh --keygen)"
            echo "  $0 --server http://sfspark1.local:8080 --key YOUR_KEY"
            echo ""
            echo "  # Re-join after disconnect"
            echo "  $0 --join --key YOUR_KEY"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage"
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Installation functions
# ─────────────────────────────────────────────────────────────────────────────

install_tailscale_linux() {
    if command -v tailscale &>/dev/null; then
        ok "Tailscale already installed: $(tailscale version | head -1)"
        return 0
    fi

    info "Installing Tailscale client..."

    # Use official install script - works on Ubuntu, Debian, etc.
    # The script auto-detects distro and architecture
    curl -fsSL https://tailscale.com/install.sh | sh

    # Enable the daemon (but don't start yet - we'll configure first)
    sudo systemctl enable tailscaled

    ok "Tailscale client installed"
}

install_tailscale_wsl2() {
    # WSL2 can run its own Tailscale instance (not dependent on Windows)
    # This gives us better control and works with Headscale
    install_tailscale_linux
}

install_tailscale_windows() {
    if command -v tailscale &>/dev/null; then
        ok "Tailscale already available in PATH"
        return 0
    fi

    info "Installing Tailscale via winget..."

    if ! command -v winget &>/dev/null; then
        error "winget not found. Please install Tailscale manually"
        echo "  Download from: https://pkgs.tailscale.com/stable/"
        return 1
    fi

    winget install -e --id Tailscale.Tailscale --accept-package-agreements --accept-source-agreements || {
        warn "winget install may have failed - check if Tailscale is already installed"
    }

    ok "Tailscale installation initiated"
    echo "  Note: You may need to restart your shell"
}

install_syncthing_ubuntu() {
    if command -v syncthing &>/dev/null; then
        ok "Syncthing already installed: $(syncthing --version | head -1)"
        return 0
    fi

    info "Installing Syncthing..."

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://syncthing.net/release-key.gpg | \
        sudo tee /etc/apt/keyrings/syncthing-archive-keyring.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" | \
        sudo tee /etc/apt/sources.list.d/syncthing.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y syncthing

    ok "Syncthing installed"
}

install_syncthing_windows() {
    if command -v syncthing &>/dev/null; then
        ok "Syncthing already available in PATH"
        return 0
    fi

    info "Installing Syncthing via winget..."

    if ! command -v winget &>/dev/null; then
        error "winget not found. Please install Syncthing manually"
        return 1
    fi

    winget install -e --id Syncthing.Syncthing --accept-package-agreements --accept-source-agreements || {
        warn "winget install may have failed - check if Syncthing is already installed"
    }

    ok "Syncthing installation initiated"
}

# ─────────────────────────────────────────────────────────────────────────────
# Configuration functions
# ─────────────────────────────────────────────────────────────────────────────

configure_ssh() {
    info "Configuring SSH for mesh network..."
    prepend_ssh_config "$(get_mesh_ssh_config)"
}

configure_syncthing_ports() {
    local config_dir gui_port sync_port
    config_dir=$(get_syncthing_config_dir)
    gui_port=$(get_syncthing_port)
    sync_port=$(get_syncthing_sync_port)

    info "Configuring Syncthing ports (GUI: $gui_port, Sync: $sync_port)..."

    if [[ ! -f "$config_dir/config.xml" ]]; then
        info "Syncthing config not found - will be created on first run"
        echo "  Run syncthing once to generate config, then re-run this script"
        return 0
    fi

    # Update GUI address
    if grep -q "<address>127.0.0.1:$gui_port</address>" "$config_dir/config.xml"; then
        ok "GUI port already set to $gui_port"
    else
        sed -i "s|<address>127.0.0.1:[0-9]*</address>|<address>127.0.0.1:$gui_port</address>|" \
            "$config_dir/config.xml"
        ok "GUI port updated to $gui_port"
    fi

    # Update sync listen address
    local ports_changed=false
    if grep -q "<listenAddress>tcp://:$sync_port</listenAddress>" "$config_dir/config.xml"; then
        ok "Sync port already set to $sync_port"
    else
        sed -i "s|<listenAddress>tcp://:[0-9]*</listenAddress>|<listenAddress>tcp://:$sync_port</listenAddress>|" \
            "$config_dir/config.xml"
        sed -i "s|<listenAddress>default</listenAddress>|<listenAddress>tcp://:$sync_port</listenAddress>|" \
            "$config_dir/config.xml"
        ok "Sync port updated to $sync_port"
        ports_changed=true
    fi

    # Restart if needed
    if [[ "$ports_changed" == "true" ]] && syncthing_running; then
        info "Restarting Syncthing to apply port changes..."
        if has_systemd; then
            systemctl --user restart syncthing.service 2>/dev/null || \
                sudo systemctl restart syncthing@$USER 2>/dev/null || true
        fi
        ok "Syncthing restarted"
    fi
}

configure_wsl2_ssh_server() {
    info "Configuring SSH server for WSL2 (port 2222)..."

    if ! has_systemd; then
        warn "systemd not enabled in WSL2"
        echo ""
        echo "  Enable systemd by adding to /etc/wsl.conf:"
        echo "    [boot]"
        echo "    systemd=true"
        echo ""
        echo "  Then restart WSL: wsl --shutdown"
        return 1
    fi

    # Install openssh-server if needed
    if ! command -v sshd &>/dev/null; then
        info "Installing openssh-server..."
        sudo apt-get update
        sudo apt-get install -y openssh-server
    fi

    # Configure port 2222
    if grep -q "^Port 2222" /etc/ssh/sshd_config 2>/dev/null; then
        ok "SSH already configured for port 2222"
    else
        sudo sed -i '/^#*Port /d' /etc/ssh/sshd_config
        echo "Port 2222" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        ok "SSH port set to 2222"
    fi

    sudo systemctl enable ssh
    sudo systemctl restart ssh

    ok "SSH server enabled and running on port 2222"
}

enable_syncthing_service_linux() {
    info "Enabling Syncthing service..."

    if ! has_systemd; then
        warn "systemd not available - Syncthing must be started manually"
        return 0
    fi

    systemctl --user enable syncthing.service 2>/dev/null || {
        warn "User service not found - using system service"
        sudo systemctl enable syncthing@$USER 2>/dev/null || true
    }

    if ! syncthing_running; then
        systemctl --user start syncthing.service 2>/dev/null || \
            sudo systemctl start syncthing@$USER 2>/dev/null || true
    fi

    ok "Syncthing service enabled"
}

create_shared_folder() {
    local folder_path
    folder_path=$(get_shared_folder_path)

    if [[ "$ENV_TYPE" == "windows" ]]; then
        info "On Windows, create shared folder at: $folder_path"
        if [[ ! -d "/c/shared" ]] && [[ ! -d "C:/shared" ]]; then
            mkdir -p "C:/shared" 2>/dev/null || {
                echo "  Please create C:\\shared manually"
            }
        fi
    else
        if [[ ! -d "$folder_path" ]]; then
            info "Creating shared folder at $folder_path..."
            sudo mkdir -p "$folder_path"
            sudo chown "$USER:$USER" "$folder_path"
            ok "Created $folder_path"
        else
            ok "Shared folder exists: $folder_path"
        fi
    fi
}

deploy_stignore() {
    local folder_path
    folder_path=$(get_shared_folder_path)
    local stignore_path="$folder_path/.stignore"

    if [[ "$ENV_TYPE" == "windows" ]]; then
        stignore_path="C:/shared/.stignore"
    fi

    if [[ -f "$stignore_path" ]]; then
        ok ".stignore already exists"
        return 0
    fi

    if [[ -d "$folder_path" ]] || [[ -d "C:/shared" ]]; then
        info "Creating .stignore..."
        get_syncthing_stignore > "$stignore_path" 2>/dev/null || {
            warn "Could not create .stignore - create manually"
        }
        ok ".stignore created"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Tailscale/Headscale connection
# ─────────────────────────────────────────────────────────────────────────────

join_mesh() {
    local server_url="$1"
    local auth_key="$2"

    section "Joining Mesh Network"
    echo ""

    # Validate inputs
    if [[ -z "$server_url" ]]; then
        server_url=$(get_headscale_server)
        if [[ -z "$server_url" ]]; then
            error "No Headscale server URL provided"
            echo "  Use: $0 --server URL --key KEY"
            exit $EXIT_PREREQ
        fi
        info "Using saved server: $server_url"
    fi

    if [[ -z "$auth_key" ]]; then
        error "No pre-auth key provided"
        echo ""
        echo "  Get a key from the Headscale server:"
        echo "    sudo ./setup-headscale-server.sh --keygen"
        echo ""
        echo "  Then run:"
        echo "    $0 --server $server_url --key YOUR_KEY"
        exit $EXIT_PREREQ
    fi

    # Save server URL for future use
    save_headscale_server "$server_url"

    # Check if already connected
    if tailscale_connected; then
        ok "Already connected to mesh network"
        tailscale status
        echo ""
        read -p "Re-authenticate with new key? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi

    # Ensure tailscaled is running
    if has_systemd; then
        sudo systemctl start tailscaled 2>/dev/null || true
    fi

    # Connect to Headscale server
    info "Connecting to Headscale at $server_url..."

    sudo tailscale up --login-server="$server_url" --authkey="$auth_key" --accept-routes

    if tailscale_connected; then
        ok "Connected to mesh network"
        echo ""
        tailscale status
    else
        error "Failed to connect - check server URL and auth key"
        exit $EXIT_ERROR
    fi
}

show_status() {
    section "Mesh Network Status"
    echo ""

    detect_environment
    print_environment
    echo ""

    local server_url
    server_url=$(get_headscale_server)
    echo "  Headscale Server: $server_url"
    echo ""

    if tailscale_connected; then
        ok "Tailscale: connected"
        echo ""
        tailscale status
    else
        warn "Tailscale: not connected"
        echo ""
        echo "  Join with: $0 --server $server_url --key YOUR_KEY"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Windows elevated setup (from WSL2)
# ─────────────────────────────────────────────────────────────────────────────

setup_windows_from_wsl2() {
    local ps_script="$SCRIPT_DIR/setup-mesh.ps1"

    if [[ ! -f "$ps_script" ]]; then
        error "PowerShell script not found: $ps_script"
        return 1
    fi

    echo ""
    echo "This will configure Windows components (requires elevation)."
    echo "A UAC prompt will appear on Windows - please approve it."
    echo ""
    read -p "Configure Windows now? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Skipping Windows setup"
        return 0
    fi

    # Pass Headscale server URL to PowerShell script
    local server_url
    server_url=$(get_headscale_server)
    invoke_powershell_elevated "$ps_script" -All -HeadscaleServer "$server_url"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main setup flow
# ─────────────────────────────────────────────────────────────────────────────

main_setup() {
    section "Mesh Network Client Setup"
    echo ""

    detect_environment
    print_environment
    echo ""

    # Preflight
    if ! require_commands curl; then
        error "curl is required but not installed"
        exit $EXIT_PREREQ
    fi

    # Validate we have server and key for initial setup
    if [[ -z "$HEADSCALE_SERVER" ]]; then
        HEADSCALE_SERVER=$(get_headscale_server)
    fi

    if [[ -z "$HEADSCALE_SERVER" ]] || [[ -z "$PREAUTH_KEY" ]]; then
        error "Server URL and pre-auth key required for initial setup"
        echo ""
        echo "Usage:"
        echo "  $0 --server http://sfspark1.local:8080 --key YOUR_KEY"
        echo ""
        echo "Get a key from sfspark1:"
        echo "  sudo ./setup-headscale-server.sh --keygen"
        exit $EXIT_PREREQ
    fi

    case "$ENV_TYPE" in
        ubuntu)
            step_init 7
            step "Installing Tailscale client"
            install_tailscale_linux

            step "Installing Syncthing"
            install_syncthing_ubuntu

            step "Configuring SSH"
            configure_ssh

            step "Creating shared folder"
            create_shared_folder
            deploy_stignore

            step "Configuring Syncthing ports"
            configure_syncthing_ports

            step "Enabling services"
            enable_syncthing_service_linux

            step "Joining mesh network"
            join_mesh "$HEADSCALE_SERVER" "$PREAUTH_KEY"
            ;;

        wsl2)
            step_init 8
            step "Installing Tailscale client"
            install_tailscale_wsl2

            step "Installing Syncthing"
            install_syncthing_ubuntu

            step "Configuring SSH server (port 2222)"
            configure_wsl2_ssh_server

            step "Configuring SSH client"
            configure_ssh

            step "Creating shared folder"
            create_shared_folder
            deploy_stignore

            step "Configuring Syncthing ports"
            configure_syncthing_ports

            step "Enabling services"
            enable_syncthing_service_linux

            step "Joining mesh network"
            join_mesh "$HEADSCALE_SERVER" "$PREAUTH_KEY"

            # Offer Windows setup
            if can_run_windows_exe; then
                echo ""
                section "Windows Host Setup"
                setup_windows_from_wsl2
            fi
            ;;

        windows)
            step_init 6
            step "Installing Tailscale client"
            install_tailscale_windows

            step "Installing Syncthing"
            install_syncthing_windows

            step "Configuring SSH"
            configure_ssh

            step "Creating shared folder"
            create_shared_folder
            deploy_stignore

            step "Configuring Syncthing ports"
            configure_syncthing_ports

            echo ""
            info "Note: Run setup-mesh.ps1 as Administrator for firewall and service setup"
            info "Then join mesh with: tailscale up --login-server=$HEADSCALE_SERVER --authkey=YOUR_KEY"
            ;;

        *)
            error "Unsupported environment: $ENV_TYPE"
            exit $EXIT_PREREQ
            ;;
    esac

    # Summary
    section "Setup Complete"
    echo ""
    echo "Mesh network client is configured."
    echo ""
    echo "Commands:"
    echo "  Check status:     $SCRIPT_DIR/mesh-status.sh"
    echo "  Add Syncthing peer: $SCRIPT_DIR/add-syncthing-peer.sh"
    echo ""

    if [[ "$ENV_TYPE" == "wsl2" ]]; then
        echo "WSL2 notes:"
        echo "  - SSH server running on port 2222"
        echo "  - Syncthing GUI: http://localhost:$(get_syncthing_port)"
        echo ""
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

case "$ACTION" in
    setup)  main_setup ;;
    join)   join_mesh "$HEADSCALE_SERVER" "$PREAUTH_KEY" ;;
    status) show_status ;;
esac
