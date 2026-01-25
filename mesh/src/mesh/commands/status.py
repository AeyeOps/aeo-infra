"""Status command for mesh network health check."""

import typer

from mesh.core import tailscale
from mesh.core.config import get_headscale_server, get_syncthing_port
from mesh.core.environment import detect_os_type, detect_role, get_hostname
from mesh.core.syncthing import SyncthingClient
from mesh.utils.output import create_table, error, info, ok, print_table, section, warn


def status(
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Show detailed diagnostics"),
) -> None:
    """Show mesh network status."""
    section("Environment")
    info(f"Hostname: {get_hostname()}")
    info(f"OS Type: {detect_os_type().value}")
    info(f"Role: {detect_role().value}")

    issues = 0

    # Tailscale status
    section("Tailscale")
    if not tailscale.is_installed():
        error("Tailscale is not installed")
        issues += 1
    elif not tailscale.is_connected():
        warn("Tailscale is not connected")
        issues += 1
    else:
        ok("Tailscale is connected")
        ip = tailscale.get_ip()
        if ip:
            info(f"IP: {ip}")

        if verbose:
            peers = tailscale.get_peers()
            if peers:
                table = create_table("Tailscale Peers", ["Hostname", "IP", "Status"])
                for peer in peers:
                    status_str = "[green]online[/green]" if peer["online"] else "[red]offline[/red]"
                    table.add_row(peer["hostname"], peer["ip"], status_str)
                print_table(table)

    # Syncthing status
    section("Syncthing")
    port = get_syncthing_port()
    client = SyncthingClient(port)

    if not client.is_running():
        warn(f"Syncthing is not running (port {port})")
        issues += 1
    else:
        ok(f"Syncthing is running on port {port}")
        try:
            device_id = client.get_device_id()
            short_id = device_id[:7] + "..."
            info(f"Device ID: {short_id}")

            if verbose:
                info(f"Full Device ID: {device_id}")

                # Show connected devices
                connections = client.get_connections()
                connected = connections.get("connections", {})
                if connected:
                    info(f"Connected peers: {len(connected)}")
                    for peer_id, conn_info in connected.items():
                        if conn_info.get("connected"):
                            short_peer = peer_id[:7] + "..."
                            info(f"  - {short_peer}")
        except Exception as e:
            warn(f"Could not get Syncthing info: {e}")
            issues += 1

    # Server URL
    section("Configuration")
    server = get_headscale_server()
    if server:
        info(f"Headscale server: {server}")
    else:
        info("No Headscale server configured")

    # Summary
    section("Summary")
    if issues == 0:
        ok("All systems operational")
    else:
        warn(f"{issues} issue(s) detected")
        if not verbose:
            info("Run with --verbose for more details")
