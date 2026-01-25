#!/bin/bash
# SSHFS Client Setup Script for office-one (WSL2)
# Installs SSHFS and mounts the sfspark1 share
#
# Prerequisites: SSH key must be copied to sfspark1 first
#   ssh-copy-id steve@sfspark1.local
#
# Run this on office-one (WSL2)

set -e

SERVER="sfspark1.local"
SERVER_USER="steve"
REMOTE_PATH="/opt/shared"
LOCAL_PATH="/opt/shared"
USER="${USER:-steve}"

echo "=== SSHFS Client Setup for office-one (WSL2) ==="

# Test SSH connectivity first
echo "Testing SSH connectivity to $SERVER..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SERVER_USER@$SERVER" echo "SSH OK" 2>/dev/null; then
    echo ""
    echo "ERROR: Cannot connect to $SERVER via SSH."
    echo ""
    echo "Please copy your SSH key first:"
    echo "  ssh-copy-id $SERVER_USER@$SERVER"
    echo ""
    echo "Then re-run this script."
    exit 1
fi

# Install SSHFS if not present
if ! command -v sshfs &>/dev/null; then
    echo "Installing SSHFS..."
    sudo apt update && sudo apt install -y sshfs
else
    echo "SSHFS already installed."
fi

# Create mount point
echo "Creating mount point at $LOCAL_PATH..."
if [ ! -d "$LOCAL_PATH" ]; then
    sudo mkdir -p "$LOCAL_PATH"
    sudo chown "$USER:$USER" "$LOCAL_PATH"
else
    echo "Mount point already exists."
fi

# Check ownership
if [ "$(stat -c '%U' "$LOCAL_PATH")" != "$USER" ]; then
    echo "Fixing ownership of $LOCAL_PATH..."
    sudo chown "$USER:$USER" "$LOCAL_PATH"
fi

# Unmount if already mounted (stale mount)
if mountpoint -q "$LOCAL_PATH" 2>/dev/null; then
    echo "Unmounting existing mount..."
    fusermount -u "$LOCAL_PATH" 2>/dev/null || true
fi

# Mount
echo "Mounting $SERVER:$REMOTE_PATH to $LOCAL_PATH..."
sshfs "$SERVER_USER@$SERVER:$REMOTE_PATH" "$LOCAL_PATH"

# Verify
echo ""
echo "=== Verification ==="
if mountpoint -q "$LOCAL_PATH"; then
    echo "Mount successful!"
    echo ""
    ls -la "$LOCAL_PATH"
    echo ""
    df -h "$LOCAL_PATH"
else
    echo "ERROR: Mount failed!"
    exit 1
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To auto-mount on login, add this to ~/.bashrc:"
echo ""
echo '  # Auto-mount sfspark1 share'
echo '  if ! mountpoint -q /opt/shared 2>/dev/null; then'
echo '      sshfs steve@sfspark1.local:/opt/shared /opt/shared 2>/dev/null'
echo '  fi'
