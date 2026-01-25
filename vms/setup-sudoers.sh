#!/bin/bash
# Setup NOPASSWD sudoers entries for VM management
# Run with sudo: sudo ./setup-sudoers.sh
#
# This creates a NEW file in /etc/sudoers.d/ and does NOT modify
# existing sudoers entries. Safe to run multiple times.

set -e

SUDOERS_FILE="/etc/sudoers.d/vm-management"
USER="${SUDO_USER:-$(id -un)}"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

if [[ -z "$USER" || "$USER" == "root" ]]; then
    echo "Error: Could not determine non-root user"
    echo "Run as: sudo -u youruser sudo $0"
    exit 1
fi

echo "Setting up NOPASSWD entries for user: $USER"
echo "Sudoers file: $SUDOERS_FILE"
echo ""

# Build list of commands with full paths
# Only include commands that exist on the system
CMDS=()

add_cmd() {
    local cmd="$1"
    local path
    path=$(command -v "$cmd" 2>/dev/null) || path=$(which "$cmd" 2>/dev/null) || true
    if [[ -n "$path" && -x "$path" ]]; then
        CMDS+=("$path")
        echo "  + $path"
    else
        echo "  - $cmd (not found, skipping)"
    fi
}

echo "Commands to add:"

# VM management scripts (this directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for script in "$SCRIPT_DIR"/*.sh; do
    if [[ -x "$script" && "$(basename "$script")" != "setup-sudoers.sh" ]]; then
        CMDS+=("$script")
        echo "  + $script"
    fi
done

# Network management
add_cmd ip
add_cmd iptables
add_cmd iptables-legacy  # fallback

# Package management
add_cmd apt-get

# File operations (for /storage/)
add_cmd mkdir
add_cmd chmod
add_cmd chown
add_cmd truncate
add_cmd wget

# QEMU
add_cmd qemu-system-aarch64
add_cmd qemu-img

# Process management
add_cmd kill

# Misc
add_cmd nc
add_cmd tee

echo ""

if [[ ${#CMDS[@]} -eq 0 ]]; then
    echo "Error: No commands found to add"
    exit 1
fi

# Build sudoers content
# Format: user ALL=(ALL) NOPASSWD: /path/to/cmd1, /path/to/cmd2, ...
CONTENT="# VM management commands - auto-generated $(date +%Y-%m-%d)
# User: $USER
# Safe to delete this file to revoke permissions

$USER ALL=(ALL) NOPASSWD: $(IFS=', '; echo "${CMDS[*]}")
"

# Write to temp file first
TEMP_FILE=$(mktemp)
echo "$CONTENT" > "$TEMP_FILE"
chmod 440 "$TEMP_FILE"

# Validate syntax
echo "Validating sudoers syntax..."
if ! visudo -c -f "$TEMP_FILE" 2>&1; then
    echo "Error: Invalid sudoers syntax"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Check if file already exists with same content
if [[ -f "$SUDOERS_FILE" ]]; then
    if diff -q "$TEMP_FILE" "$SUDOERS_FILE" &>/dev/null; then
        echo "Sudoers file already up to date"
        rm -f "$TEMP_FILE"
        exit 0
    fi
    echo "Updating existing file..."
fi

# Install
mv "$TEMP_FILE" "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"

echo ""
echo "=== Done ==="
echo "Created: $SUDOERS_FILE"
echo ""
echo "To verify:"
echo "  sudo -l | grep NOPASSWD"
echo ""
echo "To remove:"
echo "  sudo rm $SUDOERS_FILE"
