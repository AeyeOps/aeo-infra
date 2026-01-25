"""Tailscale client management."""

import json

from mesh.utils.process import command_exists, run


def is_installed() -> bool:
    """Check if Tailscale is installed."""
    return command_exists("tailscale")


def is_connected() -> bool:
    """Check if Tailscale is connected."""
    if not is_installed():
        return False
    result = run(["tailscale", "status", "--json"])
    if not result.success:
        return False
    try:
        status = json.loads(result.stdout)
        return status.get("BackendState") == "Running"
    except json.JSONDecodeError:
        return False


def get_status() -> dict | None:
    """Get Tailscale status as dict."""
    if not is_installed():
        return None
    result = run(["tailscale", "status", "--json"])
    if not result.success:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def get_ip() -> str | None:
    """Get Tailscale IP address."""
    result = run(["tailscale", "ip", "-4"])
    if result.success and result.stdout.strip():
        return result.stdout.strip().split("\n")[0]
    return None


def up(login_server: str, auth_key: str) -> bool:
    """Connect to Tailscale with auth key."""
    result = run(
        [
            "tailscale",
            "up",
            "--login-server",
            login_server,
            "--auth-key",
            auth_key,
            "--accept-routes",
        ]
    )
    return result.success


def down() -> bool:
    """Disconnect from Tailscale."""
    result = run(["tailscale", "down"])
    return result.success


def get_peers() -> list[dict]:
    """Get list of connected peers."""
    status = get_status()
    if not status:
        return []
    peers = []
    for peer_id, peer_info in status.get("Peer", {}).items():
        peers.append(
            {
                "id": peer_id,
                "hostname": peer_info.get("HostName", ""),
                "ip": peer_info.get("TailscaleIPs", [""])[0]
                if peer_info.get("TailscaleIPs")
                else "",
                "online": peer_info.get("Online", False),
            }
        )
    return peers
