"""Syncthing peer exchange command."""

import typer
from rich.prompt import Prompt

from mesh.core.config import get_syncthing_port
from mesh.core.syncthing import SyncthingClient
from mesh.utils.output import error, info, ok, section, warn


def validate_device_id(device_id: str) -> bool:
    """Validate Syncthing device ID format."""
    # Device IDs are 52 characters, base32 encoded with dashes
    clean_id = device_id.replace("-", "")
    if len(clean_id) < 52:
        return False
    # Should be alphanumeric (base32)
    return clean_id.isalnum()


def peer() -> None:
    """Interactive Syncthing peer exchange."""
    section("Syncthing Peer Exchange")

    port = get_syncthing_port()
    client = SyncthingClient(port)

    if not client.is_running():
        error(f"Syncthing is not running on port {port}")
        info("Start Syncthing first, then run this command again")
        raise typer.Exit(1)

    # Get and display local device ID
    try:
        device_id = client.get_device_id()
    except Exception as e:
        error(f"Could not get device ID: {e}")
        raise typer.Exit(1) from None

    info("Your Device ID (share this with peers):")
    typer.echo(f"\n  {device_id}\n")

    # Show existing devices
    try:
        devices = client.get_devices()
        if len(devices) > 1:  # More than just self
            info("Currently configured devices:")
            for device in devices:
                if device.get("deviceID") != device_id:
                    name = device.get("name", "unnamed")
                    short_id = device.get("deviceID", "")[:7] + "..."
                    typer.echo(f"  - {name} ({short_id})")
            typer.echo()
    except Exception:
        pass  # Non-critical

    # Prompt for peer device ID
    section("Add a Peer")
    info("Enter the device ID of the peer you want to add")
    info("(or 'q' to quit)")

    peer_id = Prompt.ask("\nPeer Device ID")

    if peer_id.lower() == "q":
        info("Cancelled")
        raise typer.Exit(0)

    if not validate_device_id(peer_id):
        error("Invalid device ID format")
        info("Device IDs are 52+ characters with dashes, e.g. XXXXXXX-XXXXXXX-...")
        raise typer.Exit(1)

    if peer_id == device_id:
        error("Cannot add yourself as a peer")
        raise typer.Exit(1)

    # Get peer name
    peer_name = Prompt.ask("Peer name (e.g., sfspark1)", default="peer")

    # Add the device
    info(f"Adding device '{peer_name}'...")
    try:
        client.add_device(peer_id, peer_name)
        ok(f"Device '{peer_name}' added")
    except Exception as e:
        error(f"Failed to add device: {e}")
        raise typer.Exit(1) from None

    # Share opt-shared folder if it exists
    try:
        folders = client.get_folders()
        shared_folder = next((f for f in folders if "shared" in f.get("id", "").lower()), None)
        if shared_folder:
            folder_id = shared_folder["id"]
            info(f"Sharing folder '{folder_id}' with {peer_name}...")
            client.share_folder(folder_id, peer_id)
            ok(f"Folder shared with {peer_name}")
    except Exception as e:
        warn(f"Could not share folder: {e}")
        info("You may need to share folders manually in the Syncthing GUI")

    section("Next Steps")
    info("1. The peer needs to accept this device in their Syncthing GUI")
    info("2. Once accepted, folder sync will begin automatically")
    info("3. Check status with: mesh status --verbose")
