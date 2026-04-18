#!/usr/bin/env bash
# Integration test orchestrator for mesh CLI
# Spins up a heterogeneous mesh on a single shared bridge (br-vm):
#   - Headscale + 2 Linux clients (Docker) at 192.168.50.10/.11/.12
#   - 2 Windows clients (QEMU) with dynamic DHCP leases in .100-.199
# Usage: ./tests/integration/run-tests.sh [pytest args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MESH_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$(cd "$MESH_DIR/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT="meshtest"

# Windows VM infrastructure — two distinct VMs, IPs discovered dynamically
WINVM_SH="${REPO_DIR}/vms/winvm.sh"
WIN_NAMES=(meshtest-win-a meshtest-win-b)
WIN_USER="testuser"

# Single Headscale URL on the shared bridge — no host port-forward hairpin
HEADSCALE_URL="http://192.168.50.10:8080"

cleanup() {
    echo "--- Tearing down ---"
    for name in "${WIN_NAMES[@]}"; do
        echo "  Stopping Windows VM $name..."
        sudo "$WINVM_SH" destroy "$name" 2>/dev/null || true
    done
    echo "  Stopping Docker containers..."
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    # dnsmasq holds the old br-vm lease file open; kill it so the next run
    # starts with a fresh bridge owned by Docker.
    if [[ -f /run/dnsmasq-br-vm.pid ]]; then
        sudo kill "$(cat /run/dnsmasq-br-vm.pid)" 2>/dev/null || true
        sudo rm -f /run/dnsmasq-br-vm.pid /run/dnsmasq-br-vm.leases 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Pre-flight: if br-vm was left behind (e.g., by `winvm.sh image build`),
# Docker's bridge driver will silently create a new auto-named bridge
# instead of honouring `com.docker.network.bridge.name: br-vm`. Tear it
# down so Docker can create br-vm afresh with the compose config.
echo "=== Pre-flight cleanup ==="
if [[ -f /run/dnsmasq-br-vm.pid ]]; then
    sudo kill "$(cat /run/dnsmasq-br-vm.pid)" 2>/dev/null || true
    sudo rm -f /run/dnsmasq-br-vm.pid /run/dnsmasq-br-vm.leases 2>/dev/null || true
fi
if ip link show br-vm &>/dev/null; then
    echo "  Removing leftover br-vm..."
    sudo ip link delete br-vm 2>/dev/null || true
fi
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true

# Phase 1: Start Headscale
echo "=== Starting Headscale on br-vm ==="
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d headscale
echo "=== Waiting for Headscale health ==="
for i in $(seq 1 30); do
    # headscale v0.27.1 emits no output on success; trust the exit code.
    if docker exec meshtest-headscale headscale health >/dev/null 2>&1; then
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
    --user "$USER_ID" --reusable --expiration 24h -o json | \
    python3 -c "import sys,json; print(json.loads(sys.stdin.read())['key'])")
echo "  Auth key: ${AUTHKEY:0:12}..."

# Phase 3: Start Linux clients
echo "=== Starting Linux clients ==="
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d client-a client-b
sleep 3

# Phase 4: Start two Windows VMs and discover their DHCP IPs
echo "=== Starting Windows VMs ==="
declare -A WIN_IPS
for name in "${WIN_NAMES[@]}"; do
    echo "  Starting $name..."
    sudo "$WINVM_SH" start "$name"
    ip=$(sudo "$WINVM_SH" ip "$name")
    if [[ -z "$ip" ]]; then
        echo "FAIL: no DHCP lease for $name"
        exit 1
    fi
    WIN_IPS[$name]="$ip"
    echo "    $name -> $ip"
done

# Phase 5: Join all nodes to mesh
echo "=== Joining client-a ==="
docker exec meshtest-client-a tailscale up \
    --login-server="$HEADSCALE_URL" \
    --authkey="$AUTHKEY" \
    --hostname=client-a \
    --accept-routes

echo "=== Joining client-b ==="
docker exec meshtest-client-b tailscale up \
    --login-server="$HEADSCALE_URL" \
    --authkey="$AUTHKEY" \
    --hostname=client-b \
    --accept-routes

for name in "${WIN_NAMES[@]}"; do
    ip="${WIN_IPS[$name]}"
    echo "=== Joining $name ($ip) ==="
    # Windows OpenSSH defaults to CMD — use CMD-safe quoting (no PowerShell `&`).
    # `tailscale up` returns "timeout waiting for Running state" when DERP is
    # unreachable even though the node is successfully registered. Treat a
    # non-zero exit as a warning; pytest validates real connectivity.
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=12 \
        "${WIN_USER}@${ip}" \
        "\"C:\\Program Files\\Tailscale\\tailscale.exe\" up --login-server=${HEADSCALE_URL} --authkey=${AUTHKEY} --hostname=${name} --accept-routes --timeout=30s" \
        || echo "  (tailscale up exited non-zero on $name; will verify via Headscale)"
done

# Phase 6: Wait for full peer discovery (all 4 nodes visible to client-a)
echo "=== Waiting for peer discovery ==="
for i in $(seq 1 60); do
    PEERS=$(docker exec meshtest-client-a tailscale status --json 2>/dev/null | \
        python3 -c "import sys,json; print(len(json.loads(sys.stdin.read()).get('Peer',{})))" 2>/dev/null || echo "0")
    if [ "$PEERS" -ge 3 ]; then
        echo "  All peers visible (${i}s): ${PEERS} peers"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARN: Only ${PEERS} peer(s) visible after 60s (expected 3)"
    fi
    sleep 1
done

# Phase 7: Run tests
echo ""
echo "=== Running integration tests ==="
cd "$MESH_DIR"
AUTHKEY="$AUTHKEY" \
HEADSCALE_URL="$HEADSCALE_URL" \
WIN_A_IP="${WIN_IPS[meshtest-win-a]}" \
WIN_B_IP="${WIN_IPS[meshtest-win-b]}" \
WIN_USER="$WIN_USER" \
    uv run pytest tests/integration/ -v --tb=short "$@"
EXIT_CODE=$?

echo "=== Done (exit $EXIT_CODE) ==="
exit $EXIT_CODE
