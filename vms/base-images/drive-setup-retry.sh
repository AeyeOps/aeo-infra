#!/usr/bin/env bash
# Retry wrapper around exp-drive-setup.sh.
#
# Rationale: per-run cdboot dismissal via usb-kbd keyspam succeeds ~50-70%
# of the time with the Boot Manager approach. The fail modes are either
# cdboot times-out-and-returns-to-Boot-Manager, or cdboot-dismissed-but-
# bootmgfw-hangs. Both are detectable by the s4 screenshot showing a
# non-Setup frame. We retry up to 3 times.
set -euo pipefail

WORK=${WORK:-/tmp/winboot}
MAX_ATTEMPTS=${MAX_ATTEMPTS:-5}

check_setup() {
    local label=$1
    local shot=$WORK/${label}-s4-setup.png
    # Setup UI has dominant yellow/lavender pixels. Use ImageMagick to compute
    # mean color; Setup has yellow (high R+G, low B), cdboot prompt is mostly
    # black with small yellow text (low average), BootMgr menu is dark olive.
    # Simple heuristic: mean intensity > 80 → likely Setup UI.
    if [ ! -f "$shot" ]; then return 1; fi
    local mean
    mean=$(convert "$shot" -colorspace gray -format "%[fx:100*mean]" info: 2>/dev/null || echo 0)
    mean=${mean%.*}
    echo "[retry] attempt=$label mean-gray=$mean"
    [ "${mean:-0}" -gt 60 ]
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DRIVER=${DRIVER:-$SCRIPT_DIR/drive-setup.sh}

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    label="retry${attempt}"
    echo "=== attempt $attempt/$MAX_ATTEMPTS label=$label ==="
    "$DRIVER" "$label" >/dev/null 2>&1 || true
    if check_setup "$label"; then
        echo "[retry] SUCCESS on attempt $attempt"
        exit 0
    fi
    echo "[retry] attempt $attempt failed, killing qemu and retrying"
    for p in $(pgrep -f qemu-system-aarch64 || true); do
        sudo -n kill -9 "$p" 2>/dev/null || true
    done
    # Port-release settle delay
    s=$(date +%s); while [ $(($(date +%s) - s)) -lt 4 ]; do sleep 1; done
done

echo "[retry] EXHAUSTED $MAX_ATTEMPTS attempts"
exit 1
