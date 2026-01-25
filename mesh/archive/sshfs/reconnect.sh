#!/bin/bash
# Reconnect/remount SSHFS share if disconnected
# Can be run manually or via cron/systemd timer
#
# Run this on office-one (WSL2)

SERVER="sfspark1.local"
SERVER_USER="steve"
REMOTE_PATH="/opt/shared"
LOCAL_PATH="/opt/shared"

# Check if already mounted
if mountpoint -q "$LOCAL_PATH" 2>/dev/null; then
    echo "Mount is active: $LOCAL_PATH"
    exit 0
fi

echo "Mount not active, attempting reconnect..."

# Clean up any stale mount
fusermount -u "$LOCAL_PATH" 2>/dev/null || true

# Attempt mount
if sshfs "$SERVER_USER@$SERVER:$REMOTE_PATH" "$LOCAL_PATH" 2>/dev/null; then
    echo "Successfully mounted $LOCAL_PATH"
    exit 0
else
    echo "Failed to mount $LOCAL_PATH" >&2
    echo "Check: ssh $SERVER_USER@$SERVER echo test" >&2
    exit 1
fi
