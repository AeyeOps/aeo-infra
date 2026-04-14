#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <HEADSCALE_URL> <AUTH_KEY> [HOSTNAME]"
  exit 1
fi

HEADSCALE_URL="$1"
AUTH_KEY="$2"
HOSTNAME="${3:-}"

ARGS=(
  up
  --login-server "${HEADSCALE_URL}"
  --authkey "${AUTH_KEY}"
  --accept-dns=true
)

if [[ -n "${HOSTNAME}" ]]; then
  ARGS+=(--hostname "${HOSTNAME}")
fi

sudo tailscale "${ARGS[@]}"
