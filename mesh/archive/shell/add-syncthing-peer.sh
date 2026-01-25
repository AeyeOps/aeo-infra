#!/bin/bash
# Syncthing Peer Exchange
# Interactive workflow to add a new device to the Syncthing cluster
#
# This script:
#   1. Displays your local device ID (for sharing)
#   2. Prompts for the remote device ID
#   3. Adds the device via Syncthing API
#   4. Shares the opt-shared folder with the new device
#
# EXIT CODES:
#   0 - Success
#   1 - Error
#   2 - Syncthing not running

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/mesh-common.sh"

section "Syncthing Peer Exchange"
echo ""

# Detect environment
detect_environment
print_environment
echo ""

# Get configuration
ST_PORT=$(get_syncthing_port)
ST_CONFIG_DIR=$(get_syncthing_config_dir)
FOLDER_ID="opt-shared"
FOLDER_PATH=$(get_shared_folder_path)

# Check if Syncthing is running
if ! syncthing_running; then
    error "Syncthing is not running on port $ST_PORT"
    echo ""
    echo "  Start Syncthing first:"
    if has_systemd; then
        echo "    systemctl --user start syncthing"
    else
        echo "    syncthing"
    fi
    echo ""
    echo "  Or open the Web UI:"
    echo "    http://localhost:$ST_PORT"
    exit $EXIT_PREREQ
fi

# Get API key
API_KEY=$(get_syncthing_api_key) || {
    error "Could not find Syncthing API key"
    echo "  Config dir: $ST_CONFIG_DIR"
    exit $EXIT_ERROR
}

# Get local device ID
MY_ID=$(get_syncthing_device_id) || {
    error "Could not get local device ID"
    exit $EXIT_ERROR
}

MY_ID_SHORT="${MY_ID:0:7}"

echo "Your Device Information:"
echo "  Device ID (short): ${MY_ID_SHORT}..."
echo "  Device ID (full):  $MY_ID"
echo ""
echo "  Share this full ID with the peer you want to connect to."
echo ""

# Copy to clipboard if possible
if command -v xclip &>/dev/null; then
    echo "$MY_ID" | xclip -selection clipboard 2>/dev/null && \
        info "Device ID copied to clipboard"
elif command -v pbcopy &>/dev/null; then
    echo "$MY_ID" | pbcopy 2>/dev/null && \
        info "Device ID copied to clipboard"
elif [[ "$ENV_TYPE" == "wsl2" ]] && command -v clip.exe &>/dev/null; then
    echo "$MY_ID" | clip.exe 2>/dev/null && \
        info "Device ID copied to Windows clipboard"
fi

echo ""
echo "─────────────────────────────────────────────────────────────────"
echo ""

# Get peer device ID
read -p "Enter peer's device ID (or 'q' to quit): " PEER_ID

if [[ "$PEER_ID" == "q" || "$PEER_ID" == "Q" || -z "$PEER_ID" ]]; then
    info "Cancelled"
    exit 0
fi

# Validate device ID format (should be 52 characters, base32)
if [[ ! "$PEER_ID" =~ ^[A-Z0-9-]{52,63}$ ]]; then
    warn "Device ID format looks unusual (expected 52+ chars, A-Z0-9-)"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Get peer name
read -p "Enter a name for this peer (e.g., sfspark1, wsl2, windows): " PEER_NAME

if [[ -z "$PEER_NAME" ]]; then
    PEER_NAME="peer-$(date +%s)"
    info "Using default name: $PEER_NAME"
fi

echo ""
section "Adding Peer Device"

# Check if device already exists
EXISTING=$(curl -s -H "X-API-Key: $API_KEY" \
    "http://localhost:$ST_PORT/rest/config/devices" 2>/dev/null | \
    grep -o "\"deviceID\":\"$PEER_ID\"" || true)

if [[ -n "$EXISTING" ]]; then
    warn "Device already exists in configuration"
    echo ""
    read -p "Update device name to '$PEER_NAME'? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Update device name via PATCH
        curl -s -X PATCH \
            -H "X-API-Key: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"$PEER_NAME\"}" \
            "http://localhost:$ST_PORT/rest/config/devices/$PEER_ID" >/dev/null
        ok "Device name updated"
    fi
else
    # Add new device
    info "Adding device: $PEER_NAME ($PEER_ID)"

    curl -s -X POST \
        -H "X-API-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"deviceID\": \"$PEER_ID\",
            \"name\": \"$PEER_NAME\",
            \"compression\": \"metadata\",
            \"introducer\": false,
            \"skipIntroductionRemovals\": false,
            \"introducedBy\": \"\",
            \"paused\": false,
            \"allowedNetworks\": [],
            \"autoAcceptFolders\": false,
            \"maxSendKbps\": 0,
            \"maxRecvKbps\": 0,
            \"maxRequestKiB\": 0,
            \"untrusted\": false
        }" \
        "http://localhost:$ST_PORT/rest/config/devices" >/dev/null

    ok "Device added"
fi

# Share folder with the device
section "Sharing Folder"

# Check if folder exists
FOLDER_EXISTS=$(curl -s -H "X-API-Key: $API_KEY" \
    "http://localhost:$ST_PORT/rest/config/folders" 2>/dev/null | \
    grep -o "\"id\":\"$FOLDER_ID\"" || true)

if [[ -z "$FOLDER_EXISTS" ]]; then
    info "Creating folder configuration for $FOLDER_ID..."

    curl -s -X POST \
        -H "X-API-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"id\": \"$FOLDER_ID\",
            \"label\": \"Shared Workspace\",
            \"path\": \"$FOLDER_PATH\",
            \"type\": \"sendreceive\",
            \"devices\": [{\"deviceID\": \"$MY_ID\"}, {\"deviceID\": \"$PEER_ID\"}],
            \"fsWatcherEnabled\": true,
            \"fsWatcherDelayS\": 1,
            \"versioning\": {
                \"type\": \"simple\",
                \"params\": {\"keep\": \"5\"}
            }
        }" \
        "http://localhost:$ST_PORT/rest/config/folders" >/dev/null

    ok "Folder created and shared with $PEER_NAME"
else
    # Check if device is already in folder
    DEVICE_IN_FOLDER=$(curl -s -H "X-API-Key: $API_KEY" \
        "http://localhost:$ST_PORT/rest/config/folders/$FOLDER_ID" 2>/dev/null | \
        grep -o "\"deviceID\":\"$PEER_ID\"" || true)

    if [[ -n "$DEVICE_IN_FOLDER" ]]; then
        ok "Folder already shared with this device"
    else
        info "Adding device to existing folder..."

        # Get current folder config
        FOLDER_CONFIG=$(curl -s -H "X-API-Key: $API_KEY" \
            "http://localhost:$ST_PORT/rest/config/folders/$FOLDER_ID")

        # Add device to devices array using jq if available, otherwise manual
        if command -v jq &>/dev/null; then
            NEW_CONFIG=$(echo "$FOLDER_CONFIG" | jq ".devices += [{\"deviceID\": \"$PEER_ID\"}]")
            curl -s -X PUT \
                -H "X-API-Key: $API_KEY" \
                -H "Content-Type: application/json" \
                -d "$NEW_CONFIG" \
                "http://localhost:$ST_PORT/rest/config/folders/$FOLDER_ID" >/dev/null
            ok "Device added to folder"
        else
            warn "jq not installed - please add device to folder via Web UI"
            echo "  Open: http://localhost:$ST_PORT"
            echo "  Go to: Folders > $FOLDER_ID > Edit > Sharing"
        fi
    fi
fi

# Summary
echo ""
section "Setup Complete"
echo ""
echo "Device '$PEER_NAME' has been added."
echo ""
echo "Next steps:"
echo "  1. On the peer device, add YOUR device ID:"
echo "     $MY_ID"
echo ""
echo "  2. The peer must accept the connection request"
echo "     (appears in Syncthing Web UI)"
echo ""
echo "  3. Both devices must share the folder:"
echo "     Folder ID: $FOLDER_ID"
echo "     Path here: $FOLDER_PATH"
echo ""
echo "Monitor sync status:"
echo "  Web UI: http://localhost:$ST_PORT"
echo "  CLI:    $SCRIPT_DIR/mesh-status.sh"
echo ""
