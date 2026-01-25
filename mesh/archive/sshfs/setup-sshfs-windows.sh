#!/bin/bash
# SSHFS Windows Setup Script (run from WSL)
# Creates SSH key and configures access for Windows to reach sfspark1 via SSHFS-Win
#
# Usage: ./setup-sshfs-windows.sh [server] [user] [remote_path] [windows_user]
#
# SAFETY GUARANTEES:
#   - Creates new key (id_ed25519_sfspark1) alongside existing keys, never overwrites
#   - Prepends to SSH config, never replaces existing content
#   - Only appends to authorized_keys, never removes entries
#
# Prerequisites:
#   - Run from WSL (needs /mnt/c access)
#   - SSH access to sfspark1 already working from WSL
#   - WinFsp and SSHFS-Win installed (run setup-sshfs-windows.ps1 first)
#
# Exit codes:
#   0 - Success
#   1 - Fatal error (not in WSL, can't reach server)
#   2 - Partial success (software missing, verification failed)

set -e

SERVER="${1:-sfspark1.local}"
USER="${2:-steve}"
REMOTE_PATH="${3:-/opt/shared}"
WINDOWS_USER="${4:-steve}"

echo "=== SSHFS Windows Setup (from WSL) ==="
echo ""

# Step 1: Preflight Checks
echo "[1/6] Preflight checks..."

# Verify we're in WSL
if [[ ! -d /mnt/c ]]; then
    echo "  ERROR: Must run from WSL (no /mnt/c found)" >&2
    exit 1
fi
echo "  WSL environment: OK"

# Verify sfspark1 is reachable via SSH
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$USER@$SERVER" "echo ok" >/dev/null 2>&1; then
    echo "  ERROR: Cannot reach $SERVER via SSH" >&2
    echo "  Ensure SSH key is authorized: ssh-copy-id $USER@$SERVER" >&2
    exit 1
fi
echo "  SSH to $SERVER: OK"

# Step 2: SSH Key for sfspark1 (non-destructive)
echo ""
echo "[2/6] SSH key setup..."

WIN_SSH_DIR="/mnt/c/Users/$WINDOWS_USER/.ssh"
KEY_PATH="$WIN_SSH_DIR/id_ed25519_sfspark1"

# Create .ssh dir if needed
mkdir -p "$WIN_SSH_DIR"

if [[ -f "$KEY_PATH" ]]; then
    echo "  Key exists: $KEY_PATH"
    # Test if already authorized
    if ssh -i "$KEY_PATH" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$USER@$SERVER" "echo ok" >/dev/null 2>&1; then
        echo "  Already authorized on $SERVER"
    else
        echo "  Not yet authorized, checking authorized_keys..."
        PUBKEY=$(cat "$KEY_PATH.pub")
        if ssh "$USER@$SERVER" "grep -qF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null"; then
            echo "  Public key present but auth failed (check key permissions)"
        else
            echo "  Adding to authorized_keys..."
            cat "$KEY_PATH.pub" | ssh "$USER@$SERVER" "cat >> ~/.ssh/authorized_keys"
            echo "  Added"
        fi
    fi
else
    echo "  Creating key: $KEY_PATH"
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "windows-$SERVER"
    echo "  Adding to $SERVER authorized_keys..."
    cat "$KEY_PATH.pub" | ssh "$USER@$SERVER" "cat >> ~/.ssh/authorized_keys"
    echo "  Done"
fi

# Step 3: Prepend SSH Config Entry
echo ""
echo "[3/6] SSH config setup..."

WIN_SSH_CONFIG="$WIN_SSH_DIR/config"

# Check if our entry already exists
if grep -q "^Host sfspark1.local" "$WIN_SSH_CONFIG" 2>/dev/null; then
    echo "  Config entry already exists for sfspark1.local"
else
    echo "  Prepending SSH config entry..."

    # Create new config with our entry first, then existing content
    # Use cygwin path format for SSHFS-Win compatibility
    {
        echo "Host sfspark1.local"
        echo "    IdentityFile /cygdrive/c/Users/$WINDOWS_USER/.ssh/id_ed25519_sfspark1"
        echo "    StrictHostKeyChecking accept-new"
        echo "    PreferredAuthentications publickey"
        echo ""
        if [[ -f "$WIN_SSH_CONFIG" ]]; then
            cat "$WIN_SSH_CONFIG"
        fi
    } > "$WIN_SSH_CONFIG.new"

    mv "$WIN_SSH_CONFIG.new" "$WIN_SSH_CONFIG"
    echo "  Done"
fi

# Step 4: Test cygwin SSH (populates known_hosts)
echo ""
echo "[4/6] Testing cygwin SSH..."

SSHFS_SSH="C:\\Program Files\\SSHFS-Win\\bin\\ssh.exe"

# Check if SSHFS-Win is installed
if [[ ! -f "/mnt/c/Program Files/SSHFS-Win/bin/ssh.exe" ]]; then
    echo "  SSHFS-Win not installed" >&2
    echo "  Run setup-sshfs-windows.ps1 from elevated PowerShell first" >&2
    exit 2
fi

# Must run from /mnt/c for Windows exe path resolution
cd /mnt/c

# Test cygwin SSH connectivity
if pwsh.exe -Command "& '$SSHFS_SSH' -o BatchMode=yes -o ConnectTimeout=5 $USER@$SERVER 'echo ok'" 2>/dev/null | grep -q "ok"; then
    echo "  Cygwin SSH: OK"
else
    echo "  Warning: Cygwin SSH test inconclusive"
    echo "  This may still work - continuing..."
fi

# Step 5: Verify Software Installation
echo ""
echo "[5/6] Checking Windows software..."

WINFSP_OK=$(pwsh.exe -Command 'if (Test-Path "C:\Program Files (x86)\WinFsp") { "True" } else { "False" }' | tr -d '\r')
SSHFS_OK=$(pwsh.exe -Command 'if (Test-Path "C:\Program Files\SSHFS-Win") { "True" } else { "False" }' | tr -d '\r')

if [[ "$WINFSP_OK" == "True" ]]; then
    echo "  WinFsp: installed"
else
    echo "  WinFsp: NOT installed" >&2
    echo "  Run setup-sshfs-windows.ps1 from elevated PowerShell" >&2
    exit 2
fi

if [[ "$SSHFS_OK" == "True" ]]; then
    echo "  SSHFS-Win: installed"
else
    echo "  SSHFS-Win: NOT installed" >&2
    echo "  Run setup-sshfs-windows.ps1 from elevated PowerShell" >&2
    exit 2
fi

# Step 6: Verify UNC Access
echo ""
echo "[6/6] Verifying UNC path access..."

UNC_PATH="\\\\sshfs\\$USER@$SERVER$REMOTE_PATH"

# Give SSHFS-Win a moment to establish connection on first access
ACCESS_OK="False"
for attempt in 1 2 3; do
    ACCESS_OK=$(pwsh.exe -Command "if (Test-Path '$UNC_PATH') { 'True' } else { 'False' }" 2>/dev/null | tr -d '\r')
    if [[ "$ACCESS_OK" == "True" ]]; then
        break
    fi
    if [[ $attempt -lt 3 ]]; then
        echo "  Attempt $attempt/3 - waiting..."
        sleep 2
    fi
done

echo ""
echo "=== Results ==="
echo ""
echo "UNC Path: $UNC_PATH"
echo ""

if [[ "$ACCESS_OK" == "True" ]]; then
    echo "Access: VERIFIED"
    echo ""
    echo "Contents:"
    pwsh.exe -Command "Get-ChildItem '$UNC_PATH' | Select-Object -First 10 | Format-Table Name, Length, LastWriteTime" 2>/dev/null || true
    exit 0
else
    echo "Access: NOT VERIFIED" >&2
    echo ""
    echo "This may resolve after:"
    echo "  - Windows reboot"
    echo "  - Manually accessing the path in Explorer"
    echo ""
    echo "Try in Explorer: $UNC_PATH"
    exit 2
fi
