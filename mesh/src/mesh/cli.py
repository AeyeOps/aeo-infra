"""Main CLI application."""

import typer

from mesh import __version__
from mesh.commands import client, host, init, peer, remote, server, status, ubuntu, windows, wsl

app = typer.Typer(
    name="mesh",
    help="Mesh network setup tools (Headscale + Syncthing)",
    no_args_is_help=True,
    rich_markup_mode="rich",
)

# Add subcommand groups
app.add_typer(server.app, name="server")
app.add_typer(client.app, name="client")
app.add_typer(host.app, name="host")
app.add_typer(wsl.app, name="wsl")
app.add_typer(windows.app, name="windows")
app.add_typer(ubuntu.app, name="ubuntu")
app.add_typer(remote.app, name="remote")


def version_callback(value: bool) -> None:
    """Print version and exit."""
    if value:
        typer.echo(f"mesh {__version__}")
        raise typer.Exit()


@app.callback()
def main(
    version: bool = typer.Option(
        False,
        "--version",
        "-V",
        callback=version_callback,
        is_eager=True,
        help="Show version and exit.",
    ),
) -> None:
    """Mesh network setup tools (Headscale + Syncthing)."""
    pass


# Register standalone commands
app.command(name="init")(init.init)
app.command(name="status")(status.status)
app.command(name="peer")(peer.peer)


if __name__ == "__main__":
    app()
