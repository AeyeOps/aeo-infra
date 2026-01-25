#!/bin/bash
# SSH Server Setup Script for sfspark1 (NVIDIA GB10)
# Ensures SSH is configured for key-based authentication
#
# Run this on sfspark1

set -e

SHARE_DIR="/opt/shared"
USER="${USER:-steve}"

echo "=== SSHFS Server Setup for sfspark1 ==="

# Ensure SSH server is installed
if ! command -v sshd &>/dev/null; then
    echo "Installing OpenSSH server..."
    sudo apt update && sudo apt install -y openssh-server
fi

# Ensure SSH service is running
echo "Ensuring SSH service is running..."
sudo systemctl enable ssh
sudo systemctl start ssh

# Create share directory
echo "Ensuring share directory exists..."
mkdir -p "$SHARE_DIR"

# Ensure .ssh directory exists with correct permissions
echo "Checking SSH directory permissions..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Verify SSH is listening
echo ""
echo "=== Verification ==="
echo "SSH service status:"
systemctl is-active ssh

echo ""
echo "SSH listening on:"
ss -tlnp | grep :22 || echo "Warning: SSH not listening on port 22"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps on the CLIENT machine (office-one WSL2):"
echo "  1. Copy your SSH key: ssh-copy-id $USER@sfspark1.local"
echo "  2. Run: ./setup-sshfs-client.sh"
