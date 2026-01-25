"""Host registry commands for managing mesh hosts."""

import typer

from mesh.core.config import InvalidHostnameError, add_host, get_host, load_hosts, remove_host
from mesh.core.headscale import list_nodes
from mesh.utils.output import error, info, ok, section, warn
from mesh.utils.ssh import add_ssh_host, host_exists, remove_ssh_host, ssh_to_host

app = typer.Typer(
    name="host",
    help="Manage mesh host registry",
    no_args_is_help=True,
)


@app.command(name="add")
def add(
    name: str = typer.Argument(..., help="Hostname alias (e.g., 'ubu1')"),
    ip: str = typer.Option(..., "--ip", "-i", help="IP address or hostname"),
    port: int = typer.Option(22, "--port", "-p", help="SSH port"),
    user: str = typer.Option(None, "--user", "-u", help="SSH username (defaults to current user)"),
    no_ssh: bool = typer.Option(False, "--no-ssh", help="Don't add SSH config entry"),
) -> None:
    """Add a host to the mesh registry.

    This command:
    - Adds the host to ~/.config/mesh/hosts.yaml
    - Creates an SSH config entry in ~/.ssh/config

    Examples:
        mesh host add ubu1 --ip 192.168.50.10
        mesh host add ubu1 --ip 192.168.50.10 --port 22 --user ubuntu
    """
    import os

    if user is None:
        user = os.environ.get("USER", "ubuntu")
    section(f"Adding host: {name}")

    # Add to registry
    try:
        host = add_host(name, ip, port, user)
    except InvalidHostnameError as e:
        error(str(e))
        raise typer.Exit(1) from None
    ok(f"Added to registry: {host.name} ({host.ip}:{host.port})")

    # Add SSH config entry
    if not no_ssh:
        if host_exists(name):
            info(f"SSH config entry for '{name}' already exists, updating...")
        add_ssh_host(name, ip, port, user)
        ok(f"SSH config entry created: Host {name}")

    info("")
    info(f"You can now: ssh {name}")
    info(f"To provision: mesh remote provision {name}")


@app.command(name="remove")
def remove(
    name: str = typer.Argument(..., help="Hostname to remove"),
    keep_ssh: bool = typer.Option(False, "--keep-ssh", help="Keep SSH config entry"),
) -> None:
    """Remove a host from the mesh registry.

    Note: This does NOT remove the host from the mesh network.
    To fully de-provision, use Headscale commands directly.

    Examples:
        mesh host remove ubu1
        mesh host remove ubu1 --keep-ssh
    """
    section(f"Removing host: {name}")

    # Check if host exists
    host = get_host(name)
    if not host:
        error(f"Host '{name}' not found in registry")
        raise typer.Exit(1)

    # Remove from registry
    remove_host(name)
    ok(f"Removed from registry: {name}")

    # Remove SSH config entry
    if not keep_ssh:
        if remove_ssh_host(name):
            ok(f"Removed SSH config entry: {name}")
        else:
            info("No dynamic SSH config entry found (may be static)")

    warn("Note: Host is still in mesh network. To remove from mesh:")
    info("  sudo headscale nodes list")
    info("  sudo headscale nodes delete -i <NODE_ID>")


@app.command(name="list")
def list_hosts() -> None:
    """List all registered hosts with their status.

    Shows:
    - Registered: In ~/.config/mesh/hosts.yaml
    - SSH: Has SSH config entry
    - Provisioned: Appears in Headscale nodes list
    """
    section("Mesh Host Registry")

    hosts = load_hosts()
    if not hosts:
        info("No hosts registered.")
        info("Add a host: mesh host add <name> --ip <IP>")
        return

    # Get provisioned nodes from Headscale
    try:
        nodes = list_nodes(user="mesh")
        provisioned = {n.get("givenName", "").lower() for n in nodes}
    except Exception:
        provisioned = set()
        warn("Could not query Headscale (server may not be running)")

    # Display hosts
    info(f"{'NAME':<15} {'IP':<20} {'PORT':<6} {'USER':<10} {'STATUS'}")
    info("-" * 70)

    for host in hosts.values():
        # Check SSH config
        has_ssh = "SSH" if host_exists(host.name) else ""
        # Check if provisioned
        is_provisioned = "MESH" if host.name.lower() in provisioned else ""
        status = " ".join(filter(None, [has_ssh, is_provisioned])) or "registered"

        info(f"{host.name:<15} {host.ip:<20} {host.port:<6} {host.user:<10} {status}")


@app.command(name="status")
def status(
    name: str = typer.Argument(..., help="Hostname to check"),
) -> None:
    """Show detailed status of a registered host.

    Checks:
    - Registry entry
    - SSH config entry
    - SSH connectivity
    - Mesh membership (Headscale)
    """
    section(f"Host Status: {name}")

    # Check registry
    host = get_host(name)
    if not host:
        error(f"Host '{name}' not found in registry")
        info(f"Add it first: mesh host add {name} --ip <IP>")
        raise typer.Exit(1)

    ok(f"Registry: {host.ip}:{host.port} (user: {host.user})")

    # Check SSH config
    if host_exists(name):
        ok("SSH config: entry exists")
    else:
        warn("SSH config: no entry (use --no-ssh to skip)")

    # Test SSH connectivity
    info("Testing SSH connectivity...")
    target = f"{host.user}@{host.ip}"
    success, output = ssh_to_host(target, "echo connected", timeout=10, port=host.port)
    if success:
        ok("SSH: connected")
    else:
        warn(f"SSH: cannot connect ({output.strip()})")

    # Check Headscale nodes
    info("Checking mesh membership...")
    try:
        nodes = list_nodes(user="mesh")
        node_names = {n.get("givenName", "").lower() for n in nodes}
        if name.lower() in node_names:
            ok("Mesh: provisioned")
            # Find the node to show more details
            for node in nodes:
                if node.get("givenName", "").lower() == name.lower():
                    ts_ip = node.get("ipAddresses", ["?"])[0]
                    info(f"  Tailscale IP: {ts_ip}")
                    break
        else:
            warn("Mesh: not provisioned")
            info(f"  To provision: mesh remote provision {name}")
    except Exception as e:
        warn(f"Mesh: cannot query ({e})")
