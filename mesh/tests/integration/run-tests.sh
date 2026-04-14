#!/usr/bin/env bash
# Integration test orchestrator for mesh CLI hardening
# Usage: ./tests/integration/run-tests.sh [--with-windows] [pytest args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MESH_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$(cd "$MESH_DIR/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT="meshtest"

# Parse --with-windows flag
WITH_WINDOWS=0
PYTEST_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--with-windows" ]]; then
        WITH_WINDOWS=1
    else
        PYTEST_ARGS+=("$arg")
    fi
done

# Windows VM infrastructure
WINVM_SH="${REPO_DIR}/vms/winvm.sh"
WINVM_NAME="meshtest-win"
WINVM_IP="192.168.50.200"
WINVM_USER="testuser"

cleanup() {
    echo "--- Tearing down ---"
    # Tear down Windows VM if it was started
    if [[ "$WITH_WINDOWS" -eq 1 ]]; then
        echo "  Stopping Windows VM..."
        sudo "$WINVM_SH" destroy "$WINVM_NAME" 2>/dev/null || true
    fi
    # Tear down Docker containers
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# Phase 1: Start Headscale
echo "=== Starting Headscale ==="
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d headscale
echo "=== Waiting for Headscale health ==="
for i in $(seq 1 30); do
    if docker exec meshtest-headscale headscale health 2>&1 | grep -qi "ok\|healthy\|pass"; then
        echo "  Healthy (${i}s)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "FAIL: Headscale not healthy after 30s"
        docker exec meshtest-headscale headscale health 2>&1 || true
        docker logs meshtest-headscale 2>&1 | tail -20
        exit 1
    fi
    sleep 1
done

# Phase 2: Bootstrap
echo "=== Bootstrapping Headscale ==="
docker exec meshtest-headscale headscale users create testuser 2>&1 || true

USER_ID=$(docker exec meshtest-headscale headscale users list -o json | \
    python3 -c "import sys,json; print(next(u['id'] for u in json.loads(sys.stdin.read()) if u['name']=='testuser'))")
echo "  User ID: $USER_ID"

AUTHKEY=$(docker exec meshtest-headscale headscale preauthkeys create \
    --user "$USER_ID" --reusable -o json | \
    python3 -c "import sys,json; print(json.loads(sys.stdin.read())['key'])")
echo "  Auth key: ${AUTHKEY:0:12}..."

# Phase 3: Start Linux clients
echo "=== Starting Tailscale clients ==="
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d client-a client-b
sleep 3  # Wait for tailscaled to initialize

# Phase 4: Join Linux clients
echo "=== Joining client-a ==="
docker exec meshtest-client-a tailscale up \
    --login-server=http://172.30.0.10:8080 \
    --authkey="$AUTHKEY" \
    --hostname=client-a \
    --accept-routes

echo "=== Joining client-b ==="
docker exec meshtest-client-b tailscale up \
    --login-server=http://172.30.0.10:8080 \
    --authkey="$AUTHKEY" \
    --hostname=client-b \
    --accept-routes

# Phase 5: Wait for peer discovery
echo "=== Waiting for peer discovery ==="
for i in $(seq 1 20); do
    PEERS=$(docker exec meshtest-client-a tailscale status --json 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.loads(sys.stdin.read()).get('Peer',{})))" 2>/dev/null || echo "0")
    if [ "$PEERS" -ge 1 ]; then
        echo "  Peers visible (${i}s)"
        break
    fi
    if [ "$i" -eq 20 ]; then echo "  WARN: No peers after 20s"; fi
    sleep 1
done

# Phase 6 (optional): Windows VM
WINDOWS_READY=0
if [[ "$WITH_WINDOWS" -eq 1 ]]; then
    echo ""
    echo "=== Windows VM ==="

    # Check golden image
    if ! "$WINVM_SH" golden status 2>&1 | grep -q "Golden image ready"; then
        echo "SKIP: Windows golden image not found"
        echo "  Build one first: sudo ./vms/winvm.sh golden build"
        echo "  Continuing without Windows tests..."
    else
        # Headscale is port-forwarded to host:8080, accessible from
        # the QEMU bridge at 192.168.50.1:8080 (host bridge IP)
        HEADSCALE_FROM_WINDOWS="http://192.168.50.1:8080"

        echo "  Starting Windows VM '${WINVM_NAME}'..."
        sudo "$WINVM_SH" start "$WINVM_NAME" --ip "$WINVM_IP"

        echo "  Joining Windows to mesh..."
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            "${WINVM_USER}@${WINVM_IP}" \
            "& 'C:\\Program Files\\Tailscale\\tailscale.exe' up --login-server=${HEADSCALE_FROM_WINDOWS} --authkey=${AUTHKEY} --hostname=windows-test --accept-routes" \
            2>&1 || {
                echo "  WARN: Windows mesh join may have failed"
                echo "  Continuing — Windows tests may fail"
            }

        # Wait for Windows to appear as a peer
        echo "  Waiting for Windows peer..."
        for i in $(seq 1 30); do
            WIN_PEERS=$(docker exec meshtest-client-a tailscale status --json 2>/dev/null | \
                python3 -c "import sys,json; peers=json.loads(sys.stdin.read()).get('Peer',{}); print(sum(1 for p in peers.values() if 'windows' in p.get('HostName','').lower()))" 2>/dev/null || echo "0")
            if [ "$WIN_PEERS" -ge 1 ]; then
                echo "  Windows peer visible (${i}s)"
                WINDOWS_READY=1
                break
            fi
            if [ "$i" -eq 30 ]; then echo "  WARN: Windows peer not visible after 30s"; fi
            sleep 2
        done
    fi
fi

# Phase 7: Run tests
echo ""
echo "=== Running integration tests ==="
cd "$MESH_DIR"
AUTHKEY="$AUTHKEY" \
WINDOWS_READY="$WINDOWS_READY" \
WINVM_IP="$WINVM_IP" \
WINVM_USER="$WINVM_USER" \
    uv run pytest tests/integration/ -v --tb=short "${PYTEST_ARGS[@]}"
EXIT_CODE=$?

echo "=== Done (exit $EXIT_CODE) ==="
exit $EXIT_CODE
