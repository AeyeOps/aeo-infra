#!/bin/bash
# OpenSSH Server Setup for Windows - Bash Wrapper
# Run this from WSL to set up OpenSSH Server on the Windows host
#
# This script:
#   1. Launches PowerShell with elevation (UAC prompt on Windows)
#   2. Installs and configures OpenSSH Server
#   3. Copies your SSH public key for passwordless auth
#
# SAFETY:
#   - Idempotent: safe to run multiple times
#   - Requires user to approve UAC elevation on Windows
#   - Only enables built-in Windows features
#   - Key is only added if not already present

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS_SCRIPT="$SCRIPT_DIR/setup-openssh-windows.ps1"

# Convert WSL path to Windows path
PS_SCRIPT_WIN=$(wslpath -w "$PS_SCRIPT")

echo "=== OpenSSH Server Setup for Windows ==="
echo ""

# Check if we can reach Windows filesystem
if [[ ! -d /mnt/c/Windows ]]; then
    echo "ERROR: Cannot access Windows filesystem. Is this WSL?"
    exit 1
fi

# Check if PowerShell script exists
if [[ ! -f "$PS_SCRIPT" ]]; then
    echo "ERROR: PowerShell script not found at: $PS_SCRIPT"
    exit 1
fi

# Find SSH public key
SSH_KEY=""
for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "$keyfile" ]]; then
        SSH_KEY=$(cat "$keyfile")
        echo "Found SSH public key: $keyfile"
        break
    fi
done

if [[ -z "$SSH_KEY" ]]; then
    echo "WARNING: No SSH public key found in ~/.ssh/"
    echo "Key-based authentication will not be configured."
    echo "You can generate one with: ssh-keygen -t ed25519"
    echo ""
fi

echo ""
echo "This will configure OpenSSH Server on your Windows host."
echo "A UAC elevation prompt will appear on Windows - please approve it."
echo ""
echo "Launching elevated PowerShell..."
echo "(Watch for UAC prompt on Windows desktop)"
echo ""

# We need to run from a Windows directory for Windows executables to work reliably
cd /mnt/c/dev 2>/dev/null || cd /mnt/c/Users 2>/dev/null || cd /mnt/c

# Temp files - elevated PowerShell can't access WSL paths, so copy script to Windows
TEMP_DIR="/mnt/c/Users/$USER/AppData/Local/Temp"
TEMP_SCRIPT="$TEMP_DIR/setup-openssh-windows-$$.ps1"
TEMP_KEY="$TEMP_DIR/openssh-setup-key-$$.txt"
TEMP_LOG="$TEMP_DIR/openssh-setup-$$.log"
TEMP_SCRIPT_WIN="C:\\Users\\$USER\\AppData\\Local\\Temp\\setup-openssh-windows-$$.ps1"
TEMP_KEY_WIN="C:\\Users\\$USER\\AppData\\Local\\Temp\\openssh-setup-key-$$.txt"
TEMP_LOG_WIN="C:\\Users\\$USER\\AppData\\Local\\Temp\\openssh-setup-$$.log"

# Copy PowerShell script to Windows temp (elevated process can't access \\wsl.localhost paths)
cp "$PS_SCRIPT" "$TEMP_SCRIPT"

# Write SSH key to temp file if we have one
if [[ -n "$SSH_KEY" ]]; then
    echo "$SSH_KEY" > "$TEMP_KEY"
fi

# Launch PowerShell elevated with transcript logging
# Pass key file path instead of key contents to avoid quoting issues
pwsh.exe -NoProfile -Command "
    \$keyFile = '$TEMP_KEY_WIN'
    \$logFile = '$TEMP_LOG_WIN'
    \$scriptFile = '$TEMP_SCRIPT_WIN'

    \$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', \$scriptFile, '-LogFile', \$logFile)
    if (Test-Path \$keyFile) { \$argList += @('-PublicKeyFile', \$keyFile) }

    \$proc = Start-Process pwsh.exe -Verb RunAs -Wait -PassThru -ArgumentList \$argList
    exit \$proc.ExitCode
"

EXIT_CODE=$?

# Clean up temp files
rm -f "$TEMP_KEY" "$TEMP_SCRIPT" 2>/dev/null

# Display captured output
echo ""
if [[ -f "$TEMP_LOG" ]]; then
    echo "--- Elevated PowerShell Output ---"
    # Remove transcript header/footer and ANSI codes, show content
    sed -e 's/\x1b\[[0-9;]*m//g' "$TEMP_LOG" | \
        grep -v "^Transcript started\|^Transcript stopped\|^Windows PowerShell transcript\|^\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\*\|^Start time:\|^Username:\|^RunAs User:\|^Configuration Name:\|^Machine:\|^Host Application:\|^Process ID:\|^PSVersion:\|^PSEdition:\|^PSCompatibleVersions:\|^BuildVersion:\|^CLRVersion:\|^WSManStackVersion:\|^PSRemotingProtocolVersion:\|^SerializationVersion:\|^End time:" | \
        grep -v "^$" || true
    echo "--- End Output ---"
    rm -f "$TEMP_LOG"
else
    echo "WARNING: Could not capture elevated process output"
    echo "(Check if UAC was approved)"
fi

echo ""
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "=== Setup launched successfully ==="
    echo ""

    # Get Windows IP
    WIN_IP=$(cd /mnt/c/dev 2>/dev/null || cd /mnt/c; pwsh.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.InterfaceAlias -notmatch 'Loopback' -and \$_.IPAddress -notmatch '^169\.' } | Select-Object -First 1).IPAddress" 2>/dev/null | tr -d '\r\n')

    if [[ -n "$WIN_IP" ]]; then
        echo "Testing SSH connection to $WIN_IP..."
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$USER@$WIN_IP" "echo SSH_OK" 2>/dev/null | grep -q SSH_OK; then
            echo "SSH connection to $WIN_IP: SUCCESS"
            # Also add localhost to known_hosts (same server, different hostname)
            ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "$USER@localhost" "exit 0" 2>/dev/null && \
                echo "SSH connection to localhost: SUCCESS" || \
                echo "SSH connection to localhost: SKIPPED (non-critical)"
            echo ""
            echo "You can now connect with:"
            echo "  ssh $USER@$WIN_IP"
            echo "  ssh $USER@localhost"
        else
            echo "SSH connection test failed (may need a moment for service to start)"
            echo ""
            echo "Try manually:"
            echo "  ssh $USER@$WIN_IP"
        fi
    else
        echo "Could not determine Windows IP."
        echo "Check the elevated PowerShell window for results."
    fi
else
    echo "=== Setup may have failed (exit code: $EXIT_CODE) ==="
    echo ""
    echo "If UAC was cancelled, re-run this script and approve the prompt."
    echo ""
    echo "Alternatively, run manually in elevated PowerShell on Windows:"
    echo "  Set-ExecutionPolicy Bypass -Scope Process -Force"
    echo "  & '$PS_SCRIPT_WIN'"
fi
