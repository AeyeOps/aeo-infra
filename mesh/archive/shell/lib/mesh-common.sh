#!/bin/bash
# Mesh Network Common Functions
# Shared helpers for mesh network setup scripts
#
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib/mesh-common.sh"

# Exit codes
EXIT_SUCCESS=0
EXIT_ERROR=1
EXIT_PREREQ=2

# Colors (only if terminal supports them)
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null) -ge 8 ]]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────

info()  { echo "${BLUE}INFO:${RESET} $*"; }
warn()  { echo "${YELLOW}WARN:${RESET} $*" >&2; }
error() { echo "${RED}ERROR:${RESET} $*" >&2; }
die()   { error "$*"; exit $EXIT_ERROR; }
ok()    { echo "${GREEN}OK:${RESET} $*"; }

# Progress step counter
_STEP_CURRENT=0
_STEP_TOTAL=0

step_init() {
    _STEP_TOTAL=$1
    _STEP_CURRENT=0
}

step() {
    ((_STEP_CURRENT++)) || true
    echo ""
    echo "${BOLD}[${_STEP_CURRENT}/${_STEP_TOTAL}] $*${RESET}"
}

# Section header
section() {
    echo ""
    echo "=== $* ==="
}

# ─────────────────────────────────────────────────────────────────────────────
# Environment detection
# ─────────────────────────────────────────────────────────────────────────────

# Sets: ENV_TYPE (ubuntu|wsl2|windows|macos|unknown)
#       ENV_ROLE (sfspark1|wsl2|windows|unknown)
#       ENV_HOSTNAME
detect_environment() {
    ENV_HOSTNAME=$(hostname)

    # Detect OS type
    if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
        ENV_TYPE="wsl2"
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        ENV_TYPE="windows"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        ENV_TYPE="macos"
    elif [[ -f /etc/os-release ]]; then
        ENV_TYPE="ubuntu"  # Covers most Linux
    else
        ENV_TYPE="unknown"
    fi

    # Detect role based on hostname
    case "$ENV_HOSTNAME" in
        sfspark1|sfspark1.local)
            ENV_ROLE="sfspark1"
            ;;
        office-one|OFFICE-ONE)
            if [[ "$ENV_TYPE" == "wsl2" ]]; then
                ENV_ROLE="wsl2"
            else
                ENV_ROLE="windows"
            fi
            ;;
        *)
            # Fallback: use type as role for unknown hosts
            ENV_ROLE="$ENV_TYPE"
            ;;
    esac

    export ENV_TYPE ENV_ROLE ENV_HOSTNAME
}

# Print detected environment
print_environment() {
    echo "  Hostname: $ENV_HOSTNAME"
    echo "  OS Type:  $ENV_TYPE"
    echo "  Role:     $ENV_ROLE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Syncthing helpers
# ─────────────────────────────────────────────────────────────────────────────

# Get Syncthing GUI port based on role
get_syncthing_port() {
    case "${ENV_ROLE:-$(detect_environment; echo $ENV_ROLE)}" in
        sfspark1) echo "8384" ;;
        wsl2)     echo "8385" ;;
        windows)  echo "8386" ;;
        *)        echo "8384" ;;  # Default
    esac
}

# Get Syncthing sync port based on role
get_syncthing_sync_port() {
    case "${ENV_ROLE:-$(detect_environment; echo $ENV_ROLE)}" in
        sfspark1) echo "22000" ;;
        wsl2)     echo "22001" ;;
        windows)  echo "22002" ;;
        *)        echo "22000" ;;  # Default
    esac
}

# Get Syncthing config directory
get_syncthing_config_dir() {
    local env_type="${1:-$ENV_TYPE}"
    case "$env_type" in
        windows)
            # MSYS2/Git Bash on Windows
            echo "$LOCALAPPDATA/Syncthing"
            ;;
        *)
            # Linux, WSL2, macOS
            echo "$HOME/.config/syncthing"
            ;;
    esac
}

# Get Syncthing API key
get_syncthing_api_key() {
    local config_dir
    config_dir=$(get_syncthing_config_dir)

    # Try api-key file first (some versions)
    if [[ -f "$config_dir/api-key" ]]; then
        cat "$config_dir/api-key"
        return 0
    fi

    # Extract from config.xml
    if [[ -f "$config_dir/config.xml" ]]; then
        grep -oP '(?<=<apikey>)[^<]+' "$config_dir/config.xml" 2>/dev/null
        return 0
    fi

    return 1
}

# Check if Syncthing is running
syncthing_running() {
    local port
    port=$(get_syncthing_port)
    curl -s --connect-timeout 2 "http://localhost:$port/rest/system/ping" &>/dev/null
}

# Get local Syncthing device ID
get_syncthing_device_id() {
    local api_key port
    api_key=$(get_syncthing_api_key) || return 1
    port=$(get_syncthing_port)

    curl -s -H "X-API-Key: $api_key" \
        "http://localhost:$port/rest/system/status" 2>/dev/null | \
        grep -oP '"myID"\s*:\s*"\K[^"]+' || return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH helpers
# ─────────────────────────────────────────────────────────────────────────────

# Find first available SSH public key
find_ssh_public_key() {
    for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
        if [[ -f "$keyfile" ]]; then
            echo "$keyfile"
            return 0
        fi
    done
    return 1
}

# Prepend to SSH config without duplicating
prepend_ssh_config() {
    local config_content="$1"
    local ssh_config="$HOME/.ssh/config"
    local marker="# Mesh network hosts"

    # Create .ssh if needed
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Check if marker already exists
    if [[ -f "$ssh_config" ]] && grep -q "$marker" "$ssh_config"; then
        info "SSH config already contains mesh hosts (skipping)"
        return 0
    fi

    # Prepend to existing config or create new
    if [[ -f "$ssh_config" ]]; then
        local temp_config
        temp_config=$(mktemp)
        echo "$config_content" > "$temp_config"
        echo "" >> "$temp_config"
        cat "$ssh_config" >> "$temp_config"
        mv "$temp_config" "$ssh_config"
    else
        echo "$config_content" > "$ssh_config"
    fi

    chmod 600 "$ssh_config"
    ok "SSH config updated"
}

# ─────────────────────────────────────────────────────────────────────────────
# Windows interop (from WSL2)
# ─────────────────────────────────────────────────────────────────────────────

# Check if we can run Windows executables
can_run_windows_exe() {
    [[ "$ENV_TYPE" == "wsl2" ]] && command -v pwsh.exe &>/dev/null
}

# Run elevated PowerShell script from WSL2
# Usage: invoke_powershell_elevated script.ps1 [args...]
invoke_powershell_elevated() {
    local ps_script="$1"
    shift
    local args=("$@")

    if ! can_run_windows_exe; then
        error "Cannot run Windows executables from this environment"
        return 1
    fi

    # Must run from Windows path for exe interop
    local saved_dir="$PWD"
    cd /mnt/c 2>/dev/null || cd /mnt/c/Windows/Temp

    # Convert WSL path to Windows path
    local ps_script_win
    ps_script_win=$(wslpath -w "$ps_script")

    # Copy to temp location (elevated PowerShell can't access \\wsl.localhost)
    local temp_dir="/mnt/c/Users/$USER/AppData/Local/Temp"
    local temp_script="$temp_dir/mesh-setup-$$.ps1"
    local temp_script_win="C:\\Users\\$USER\\AppData\\Local\\Temp\\mesh-setup-$$.ps1"
    local temp_log="$temp_dir/mesh-setup-$$.log"
    local temp_log_win="C:\\Users\\$USER\\AppData\\Local\\Temp\\mesh-setup-$$.log"

    cp "$ps_script" "$temp_script"

    # Build argument list
    local arg_list="-NoProfile -ExecutionPolicy Bypass -File \"$temp_script_win\" -LogFile \"$temp_log_win\""
    for arg in "${args[@]}"; do
        arg_list+=" \"$arg\""
    done

    # Launch elevated
    pwsh.exe -NoProfile -Command "
        Start-Process pwsh.exe -Verb RunAs -Wait -PassThru -ArgumentList '$arg_list'
    "

    local exit_code=$?

    # Display captured output
    if [[ -f "$temp_log" ]]; then
        echo ""
        echo "--- Elevated PowerShell Output ---"
        # Remove transcript boilerplate
        sed -e 's/\x1b\[[0-9;]*m//g' "$temp_log" | \
            grep -v "^Transcript\|^Windows PowerShell\|^\*\*\*\*\*\*\|^Start time:\|^Username:\|^RunAs\|^Configuration\|^Machine:\|^Host App\|^Process ID:\|^PS.*Version\|^Build\|^CLR\|^WSMan\|^Serialization\|^End time:" | \
            grep -v "^$" || true
        echo "--- End Output ---"
        rm -f "$temp_log"
    fi

    # Cleanup
    rm -f "$temp_script"
    cd "$saved_dir" 2>/dev/null || true

    return $exit_code
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite checks
# ─────────────────────────────────────────────────────────────────────────────

# Check for required commands
require_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing[*]}"
        return 1
    fi
    return 0
}

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Check if sudo is available
has_sudo() {
    command -v sudo &>/dev/null && sudo -n true 2>/dev/null
}

# Check systemd availability (important for WSL2)
has_systemd() {
    [[ -d /run/systemd/system ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Shared configuration values
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Headscale helpers
# ─────────────────────────────────────────────────────────────────────────────

# Default Headscale server (sfspark1)
HEADSCALE_SERVER_DEFAULT="http://sfspark1.local:8080"
HEADSCALE_USER="mesh"

# Get Headscale server URL
get_headscale_server() {
    # Check environment variable first
    if [[ -n "$HEADSCALE_SERVER" ]]; then
        echo "$HEADSCALE_SERVER"
        return 0
    fi
    # Check config file
    if [[ -f "$HOME/.config/mesh/headscale-server" ]]; then
        cat "$HOME/.config/mesh/headscale-server"
        return 0
    fi
    # Default
    echo "$HEADSCALE_SERVER_DEFAULT"
}

# Save Headscale server URL
save_headscale_server() {
    local server_url="$1"
    mkdir -p "$HOME/.config/mesh"
    echo "$server_url" > "$HOME/.config/mesh/headscale-server"
}

# Check if Headscale server is reachable
headscale_server_reachable() {
    local server_url
    server_url=$(get_headscale_server)
    curl -s --connect-timeout 3 "$server_url/health" &>/dev/null
}

# Check Tailscale connection status
tailscale_connected() {
    if ! command -v tailscale &>/dev/null; then
        return 1
    fi
    tailscale status &>/dev/null && ! tailscale status 2>&1 | grep -q "Logged out\|stopped"
}

# Get Tailscale IP
get_tailscale_ip() {
    tailscale ip -4 2>/dev/null || echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Shared configuration values
# ─────────────────────────────────────────────────────────────────────────────

# Mesh network SSH config template
get_mesh_ssh_config() {
    cat << 'EOF'
# Mesh network hosts (via Headscale + mDNS)
Host sfspark1
    HostName sfspark1.local
    User steve
    IdentityFile ~/.ssh/id_ed25519

Host office-one
    HostName office-one.local
    User steve
    Port 2222
    IdentityFile ~/.ssh/id_ed25519

Host windows
    HostName office-one.local
    User steve
    Port 22
    IdentityFile ~/.ssh/id_ed25519

# Connection sharing for performance
Host *
    ControlMaster auto
    ControlPath ~/.ssh/control-%C
    ControlPersist 600
    AddKeysToAgent yes
EOF
}

# Syncthing ignore patterns
get_syncthing_stignore() {
    cat << 'EOF'
// Git lock files
.git/index.lock
.git/*.lock

// Editor temp files
*.swp
*.swo
*~
.*.swp

// Python cache
__pycache__
*.pyc
.pytest_cache

// Node modules (if any)
node_modules

// OS files
.DS_Store
Thumbs.db
EOF
}

# Shared folder path by role
# Uses forward slashes for Windows (works in bash and most Windows tools)
get_shared_folder_path() {
    local role="${1:-$ENV_ROLE}"
    case "$role" in
        windows) echo "C:/shared" ;;
        *)       echo "/opt/shared" ;;
    esac
}
