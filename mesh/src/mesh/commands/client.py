"""Client setup commands (Tailscale + Syncthing)."""

import typer

from mesh.core import headscale, tailscale
from mesh.core.config import get_headscale_server, save_headscale_server
from mesh.core.environment import OSType, detect_os_type
from mesh.utils.output import error, info, ok, section, warn
from mesh.utils.process import command_exists, run, run_sudo
from mesh.utils.ssh import add_mesh_config

app = typer.Typer(
    name="client",
    help="Client setup and connection",
    no_args_is_help=True,
)

DEFAULT_SERVER = "http://sfspark1.local:8080"


def install_tailscale_linux() -> bool:
    """Install Tailscale on Linux/WSL2."""
    info("Installing Tailscale...")
    result = run(["curl", "-fsSL", "https://tailscale.com/install.sh", "-o", "/tmp/tailscale.sh"])
    if not result.success:
        return False
    result = run_sudo(["sh", "/tmp/tailscale.sh"])
    return result.success


def install_syncthing_ubuntu() -> bool:
    """Install Syncthing on Ubuntu/WSL2."""
    info("Installing Syncthing...")
    # Add GPG key
    run_sudo(["mkdir", "-p", "/etc/apt/keyrings"])
    result = run(
        ["curl", "-fsSL", "https://syncthing.net/release-key.gpg"],
    )
    if result.success:
        from pathlib import Path

        Path("/tmp/syncthing.gpg").write_text(result.stdout)
        run_sudo(
            [
                "gpg",
                "--dearmor",
                "-o",
                "/etc/apt/keyrings/syncthing-archive-keyring.gpg",
                "/tmp/syncthing.gpg",
            ]
        )

    # Add repo
    repo_line = (
        "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] "
        "https://apt.syncthing.net/ syncthing stable"
    )
    run_sudo(["sh", "-c", f'echo "{repo_line}" > /etc/apt/sources.list.d/syncthing.list'])

    # Install
    run_sudo(["apt-get", "update"])
    result = run_sudo(["apt-get", "install", "-y", "syncthing"])
    return result.success


@app.command()
def setup(
    server: str = typer.Option(DEFAULT_SERVER, "--server", "-s", help="Headscale server URL"),
    key: str = typer.Option(..., "--key", "-k", help="Pre-authentication key"),
) -> None:
    """Install Tailscale and Syncthing, join mesh network."""
    section("Client Setup")

    os_type = detect_os_type()
    info(f"Detected OS: {os_type.value}")

    # Save server URL
    save_headscale_server(server)
    ok(f"Server URL saved: {server}")

    # Check server health
    if headscale.get_health(server):
        ok("Server is reachable")
    else:
        warn("Server health check failed - continuing anyway")

    # Install Tailscale
    if tailscale.is_installed():
        ok("Tailscale is already installed")
    else:
        if os_type in (OSType.UBUNTU, OSType.WSL2):
            if install_tailscale_linux():
                ok("Tailscale installed")
            else:
                error("Failed to install Tailscale")
                raise typer.Exit(1)
        else:
            error(f"Automatic Tailscale installation not supported on {os_type.value}")
            raise typer.Exit(1)

    # Connect to mesh
    info("Connecting to mesh network...")
    if tailscale.up(server, key):
        ok("Connected to mesh network")
        ip = tailscale.get_ip()
        if ip:
            info(f"Tailscale IP: {ip}")
    else:
        error("Failed to connect to mesh network")
        raise typer.Exit(1)

    # Install Syncthing
    if command_exists("syncthing"):
        ok("Syncthing is already installed")
    else:
        if os_type in (OSType.UBUNTU, OSType.WSL2):
            if install_syncthing_ubuntu():
                ok("Syncthing installed")
            else:
                error("Failed to install Syncthing")
                raise typer.Exit(1)
        else:
            error(f"Automatic Syncthing installation not supported on {os_type.value}")
            raise typer.Exit(1)

    # Configure SSH
    info("Configuring SSH...")
    if add_mesh_config():
        ok("SSH config updated")
    else:
        warn("Failed to update SSH config")

    section("Setup Complete")
    ok("Client is ready")
    info("Run 'mesh status' to check connectivity")
    info("Run 'mesh peer' to add Syncthing peers")


@app.command()
def join(
    key: str = typer.Option(..., "--key", "-k", help="Pre-authentication key"),
) -> None:
    """Re-join mesh network with saved server URL."""
    section("Joining Mesh Network")

    server = get_headscale_server()
    if not server:
        error("No saved server URL found")
        info("Run 'mesh client setup --server URL --key KEY' first")
        raise typer.Exit(1)

    info(f"Using server: {server}")

    if not tailscale.is_installed():
        error("Tailscale is not installed")
        info("Run 'mesh client setup' first")
        raise typer.Exit(1)

    if tailscale.up(server, key):
        ok("Connected to mesh network")
        ip = tailscale.get_ip()
        if ip:
            info(f"Tailscale IP: {ip}")
    else:
        error("Failed to connect")
        raise typer.Exit(1)
