"""Server management commands (Headscale coordination server)."""

import typer

from mesh.core import headscale
from mesh.core.environment import Role, detect_role, is_server
from mesh.utils.output import error, info, ok, section
from mesh.utils.process import run_sudo

app = typer.Typer(
    name="server",
    help="Headscale server management",
    no_args_is_help=True,
)


def require_server() -> None:
    """Ensure we're running on the coordination server."""
    if not is_server():
        role = detect_role()
        error(f"Server commands must be run on the coordination server (current role: {role.value})")
        info("Configure your server hostname with MESH_SERVER_HOSTNAMES environment variable")
        raise typer.Exit(1)


@app.command()
def setup() -> None:
    """Install and configure Headscale server."""
    require_server()

    section("Headscale Server Setup")

    if headscale.is_installed():
        ok("Headscale is already installed")
    else:
        info("Installing Headscale...")
        if headscale.install_headscale():
            ok("Headscale installed")
        else:
            error("Failed to install Headscale")
            raise typer.Exit(1)

    # Ensure service is running before creating user
    if not headscale.is_running():
        info("Starting Headscale service...")
        result = run_sudo(["systemctl", "enable", "--now", "headscale"])
        if result.success:
            ok("Headscale service started")
        else:
            error("Failed to start Headscale service")
            info("Try manually: sudo systemctl start headscale")
            raise typer.Exit(1)
    else:
        ok("Headscale service is running")

    # Create mesh user (requires running service)
    info("Creating mesh user...")
    if headscale.create_user("mesh"):
        ok("User 'mesh' ready")
    else:
        error("Failed to create user")
        raise typer.Exit(1)

    ok("Server setup complete")


@app.command()
def keygen() -> None:
    """Generate a pre-authentication key for clients."""
    require_server()

    section("Generate Pre-Auth Key")

    if not headscale.is_running():
        error("Headscale is not running")
        info("Start with: sudo systemctl start headscale")
        raise typer.Exit(1)

    key = headscale.create_preauth_key("mesh", reusable=True)
    if key:
        ok("Pre-auth key created:")
        typer.echo(f"\n  {key}\n")
        info("Use this key with: mesh client setup --key <KEY>")
    else:
        error("Failed to create pre-auth key")
        raise typer.Exit(1)


@app.command()
def status() -> None:
    """Show Headscale server status."""
    require_server()

    section("Headscale Server Status")

    if not headscale.is_installed():
        error("Headscale is not installed")
        info("Run: mesh server setup")
        raise typer.Exit(1)

    if headscale.is_running():
        ok("Service: running")
    else:
        error("Service: stopped")

    # List nodes
    nodes = headscale.list_nodes("mesh")
    if nodes:
        info(f"Registered nodes: {len(nodes)}")
        for node in nodes:
            name = node.get("givenName", node.get("name", "unknown"))
            online = "online" if node.get("online") else "offline"
            typer.echo(f"  - {name} ({online})")
    else:
        info("No nodes registered yet")
