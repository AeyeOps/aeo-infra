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

# --- Helpers --------------------------------------------------------------

# Emit the HostName of every peer currently reported Online:true by client-a's
# `tailscale status --json`. One name per line, lowercased. Empty output means
# "no online peers yet" — callers poll this.
online_peer_hostnames() {
    docker exec meshtest-client-a tailscale status --json 2>/dev/null | \
        python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
for p in data.get("Peer", {}).values():
    if p.get("Online") is True:
        name = (p.get("HostName") or "").lower()
        if name:
            print(name)
' 2>/dev/null || true
}

# True iff $1 appears (case-insensitive) in the Online peer list.
peer_is_online() {
    local want="${1,,}"
    local line
    while IFS= read -r line; do
        [[ "$line" == "$want" ]] && return 0
    done < <(online_peer_hostnames)
    return 1
}

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

# Phase 4: Start two Windows VMs in parallel with a 15 s stagger, then
# collect their DHCP-assigned IPs.
#
# WHY PARALLEL: winvm.sh start <name> blocks ~60-120 s on firmware boot +
# DHCP lease + SSH readiness. Per-VM artifacts are fully isolated (overlay
# qcow2, NVRAM, MAC, TAP iface, PID file, VNC port, QEMU monitor socket),
# so two starts can legitimately overlap. Wall-clock savings on the GB10
# ARM64 host: ~60-120 s.
#
# WHY 15 s STAGGER (not zero): the primary reason is CPU/IO burst
# de-concentration — two concurrent UEFI firmware inits and two qcow2
# overlay first-touches against the shared backing image hit the host
# hardest in the first few seconds, and a modest offset keeps them from
# overlapping. The secondary, defensive reason is DHCP: dnsmasq writes
# leases via atomic rename, so a race wouldn't corrupt the lease file,
# but staggering DHCPDISCOVERs is still cheap insurance against any
# dnsmasq internal bookkeeping quirk.
#
# DO NOT "optimize" back to sequential. The test fleet is small (2 VMs);
# if you grow it, keep the stagger and consider a small semaphore.
echo "=== Starting Windows VMs (parallel, 15 s stagger) ==="
declare -A WIN_IPS
declare -A WIN_PIDS
first=1
for name in "${WIN_NAMES[@]}"; do
    if [[ $first -eq 0 ]]; then
        sleep 15
    fi
    first=0
    echo "  Launching $name in background..."
    sudo "$WINVM_SH" start "$name" &
    WIN_PIDS[$name]=$!
done

# Iterate WIN_NAMES (indexed array, insertion-order preserving) rather
# than the associative ${!WIN_PIDS[@]} — bash < 5 does not guarantee
# associative-key iteration order, and deterministic FAIL message order
# is useful for log diffing across runs.
fail=0
for name in "${WIN_NAMES[@]}"; do
    pid="${WIN_PIDS[$name]}"
    if ! wait "$pid"; then
        echo "FAIL: winvm.sh start $name exited non-zero (pid $pid)"
        fail=1
    fi
done
if [[ $fail -ne 0 ]]; then
    exit 1
fi

for name in "${WIN_NAMES[@]}"; do
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
    # --timeout=60s: Windows tailscaled waits for Running state, which
    # includes a DERP probe pass. If DERP is unreachable or slow, that
    # alone can eat 20-30 s before login completes. 30 s has proven
    # tight enough to leave a Windows node stuck in NeedsLogin on a
    # routine run. 60 s absorbs a slow DERP probe plus first handshake
    # while staying bounded. Revisit this ceiling once the harness
    # runs against reachable DERP — it can likely drop back toward 30 s
    # as a tighter regression tripwire.
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=12 \
        "${WIN_USER}@${ip}" \
        "\"C:\\Program Files\\Tailscale\\tailscale.exe\" up --login-server=${HEADSCALE_URL} --authkey=${AUTHKEY} --hostname=${name} --accept-routes --timeout=60s" \
        || echo "  (tailscale up exited non-zero on $name; will verify via Headscale)"
done

# Phase 6: Wait for every expected peer to appear Online:true from
# client-a's view. len(Peer) is not sufficient — half-registered nodes
# (e.g. Windows stuck in NeedsLogin) show up in Peer but with Online:false,
# which today masqueraded as "all peers visible" and let a bad run proceed
# to warm-up against a node that never joined. Cap stays 60 s; behaviour
# stays warn-don't-fail so the warm-up phase still emits its own ERROR.
EXPECTED_PEERS=(client-b meshtest-win-a meshtest-win-b)
echo "=== Waiting for peer discovery (Online:true per peer) ==="
for i in $(seq 1 60); do
    missing=()
    for peer in "${EXPECTED_PEERS[@]}"; do
        peer_is_online "$peer" || missing+=("$peer")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "  All peers Online (${i}s): ${EXPECTED_PEERS[*]}"
        break
    fi
    if [[ "$i" -eq 60 ]]; then
        echo "WARN: after 60s, peers not Online from client-a: ${missing[*]}"
        echo "WARN: current Online peers: $(online_peer_hostnames | paste -sd, -)"
    fi
    sleep 1
done

# Phase 6b: Warm up direct-UDP WireGuard handshakes from client-a to each peer.
# Peer discovery via Headscale is not enough — pytest's connectivity tests have
# no retry, and the first `tailscale ping` into a cold peer can take tens of
# seconds while endpoints are exchanged and the handshake converges on br-vm.
# Retry `tailscale ping -c 1 <peer>` until success so tests see a warm tunnel.
echo "=== Warming up peer tunnels ==="
WARMUP_PEERS=(client-b meshtest-win-a meshtest-win-b)
warmup_fatal=0
for peer in "${WARMUP_PEERS[@]}"; do
    # Precondition: peer must be visible and Online:true from client-a.
    # If not, pinging it cannot succeed — do not burn 60 s waiting. Fail
    # fast with ERROR so the regression is obvious in the log instead of
    # showing up as `unknown peer` deep inside pytest.
    if ! peer_is_online "$peer"; then
        echo "  ERROR: $peer not Online from client-a — skipping warm-up."
        echo "         (Current Online peers: $(online_peer_hostnames | paste -sd, -))"
        warmup_fatal=1
        continue
    fi
    for i in $(seq 1 60); do
        if docker exec meshtest-client-a tailscale ping -c 1 "$peer" >/dev/null 2>&1; then
            echo "  $peer: ready (${i}s)"
            break
        fi
        if [ "$i" -eq 60 ]; then
            echo "  WARN: $peer did not respond to tailscale ping after 60s"
        fi
        sleep 1
    done
done
if [[ $warmup_fatal -ne 0 ]]; then
    echo "=== Warm-up precondition failed for one or more peers — aborting before pytest ==="
    echo "    Headscale node list:"
    docker exec meshtest-headscale headscale nodes list 2>&1 | sed 's/^/      /'
    echo "    client-a tailscale status:"
    docker exec meshtest-client-a tailscale status 2>&1 | sed 's/^/      /'
    exit 2
fi

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
