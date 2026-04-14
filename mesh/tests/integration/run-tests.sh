#!/usr/bin/env bash
# Integration test orchestrator for mesh CLI
# Spins up a heterogeneous mesh: Headscale + 2 Linux clients (Docker) + 1 Windows client (QEMU)
# Usage: ./tests/integration/run-tests.sh [pytest args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MESH_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$(cd "$MESH_DIR/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT="meshtest"

# Windows VM infrastructure
WINVM_SH="${REPO_DIR}/vms/winvm.sh"
WINVM_NAME="meshtest-win"
WINVM_IP="192.168.50.200"
WINVM_USER="testuser"

# Preflight: verify golden image exists
if ! "$WINVM_SH" golden status 2>&1 | grep -q "Golden image ready"; then
    echo "FAIL: Windows golden image not found"
    echo ""
    "$WINVM_SH" golden status
    echo ""
    echo "Build one first: sudo $WINVM_SH golden build"
    exit 1
fi

cleanup() {
    echo "--- Tearing down ---"
    echo "  Stopping Windows VM..."
    sudo "$WINVM_SH" destroy "$WINVM_NAME" 2>/dev/null || true
    echo "  Stopping Docker containers..."
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

# Phase 2: Bootstrap Headscale
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
echo "=== Starting Linux clients ==="
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d client-a client-b
sleep 3

# Phase 4: Start Windows VM
echo "=== Starting Windows VM ==="
sudo "$WINVM_SH" start "$WINVM_NAME" --ip "$WINVM_IP"

# Phase 5: Join all nodes to mesh
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

# Headscale is port-forwarded to host:8080, reachable from QEMU bridge at 192.168.50.1:8080
echo "=== Joining Windows ==="
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "${WINVM_USER}@${WINVM_IP}" \
    "& 'C:\\Program Files\\Tailscale\\tailscale.exe' up --login-server=http://192.168.50.1:8080 --authkey=${AUTHKEY} --hostname=windows-test --accept-routes"

# Phase 6: Wait for full peer discovery (all 3 nodes see each other)
echo "=== Waiting for peer discovery ==="
for i in $(seq 1 30); do
    PEERS=$(docker exec meshtest-client-a tailscale status --json 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.loads(sys.stdin.read()).get('Peer',{})))" 2>/dev/null || echo "0")
    if [ "$PEERS" -ge 2 ]; then
        echo "  All peers visible (${i}s): ${PEERS} peers"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARN: Only ${PEERS} peer(s) visible after 30s (expected 2)"
    fi
    sleep 1
done

# Phase 7: Run tests
echo ""
echo "=== Running integration tests ==="
cd "$MESH_DIR"
AUTHKEY="$AUTHKEY" \
WINVM_IP="$WINVM_IP" \
WINVM_USER="$WINVM_USER" \
    uv run pytest tests/integration/ -v --tb=short "$@"
EXIT_CODE=$?

echo "=== Done (exit $EXIT_CODE) ==="
exit $EXIT_CODE
