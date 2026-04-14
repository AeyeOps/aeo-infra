#!/usr/bin/env bash
# Integration test orchestrator for mesh CLI hardening
# Usage: ./tests/integration/run-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MESH_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT="meshtest"

cleanup() {
    echo "--- Tearing down ---"
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

# Phase 3: Start clients
echo "=== Starting Tailscale clients ==="
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d client-a client-b
sleep 3  # Wait for tailscaled to initialize

# Phase 4: Join clients
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

# Phase 6: Run tests
echo "=== Running integration tests ==="
cd "$MESH_DIR"
AUTHKEY="$AUTHKEY" uv run pytest tests/integration/ -v --tb=short "$@"
EXIT_CODE=$?

echo "=== Done (exit $EXIT_CODE) ==="
exit $EXIT_CODE
