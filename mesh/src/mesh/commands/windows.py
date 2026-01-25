"""Windows-specific provisioning commands."""

import os
import shlex
import subprocess
from pathlib import Path

import typer

from mesh.core.environment import OSType, detect_os_type
from mesh.utils.output import error, info, ok, section, warn
from mesh.utils.ssh import ssh_to_host

app = typer.Typer(
    name="windows",
    help="Windows provisioning commands",
    no_args_is_help=True,
)


def get_nvidia_sync_pubkey() -> str | None:
    """Get NVIDIA Sync public key from Windows.

    Returns None if:
    - NVIDIA Sync key file doesn't exist
    - ssh-keygen is not available (OpenSSH client not installed)
    - ssh-keygen fails to extract the public key
    """
    # NVIDIA Sync stores its key in AppData
    appdata = os.environ.get("LOCALAPPDATA", "")
    key_path = Path(appdata) / "NVIDIA Corporation" / "Sync" / "config" / "nvsync.key"

    if not key_path.exists():
        return None

    # Extract public key from private key using ssh-keygen
    # Note: Requires OpenSSH client (included in Windows 10/11 by default)
    try:
        result = subprocess.run(
            ["ssh-keygen", "-y", "-f", str(key_path)],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except FileNotFoundError:
        # ssh-keygen not available - OpenSSH client may not be installed
        return None
    except subprocess.TimeoutExpired:
        return None

    return None


def ensure_key_authorized(host: str, pubkey: str, comment: str = "") -> bool:
    """Ensure a public key is in the remote host's authorized_keys."""
    # Extract key body (2nd field) for comparison
    key_parts = pubkey.split()
    if len(key_parts) < 2:
        return False
    key_body = key_parts[1]

    # Check if key already exists (use shlex.quote for safe shell escaping)
    check_cmd = (
        f"grep -qF {shlex.quote(key_body)} ~/.ssh/authorized_keys 2>/dev/null && echo EXISTS"
    )
    success, output = ssh_to_host(host, check_cmd)
    if success and "EXISTS" in output:
        return True  # Already authorized

    # Add the key
    key_line = pubkey if not comment else f"{pubkey} {comment}"
    # Use printf with escaped content instead of echo with quotes
    escaped_key = shlex.quote(key_line)
    cmd = (
        f"mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
        f"printf '%s\\n' {escaped_key} >> ~/.ssh/authorized_keys && "
        f"chmod 600 ~/.ssh/authorized_keys"
    )
    success, _ = ssh_to_host(host, cmd)
    return success


@app.command()
def sync_keys(
    host: str = typer.Option("sfspark1", "--host", "-h", help="Remote host to authorize keys on"),
    user: str = typer.Option("", "--user", "-u", help="Remote username (default: current user)"),
) -> None:
    """Ensure NVIDIA Sync SSH key is authorized on remote host.

    This command:
    - Finds the NVIDIA Sync SSH key on this Windows machine
    - Ensures it's in the remote host's authorized_keys
    - Verifies the connection works

    Idempotent: safe to run multiple times.
    """
    section("NVIDIA Sync Key Provisioning")

    os_type = detect_os_type()
    if os_type != OSType.WINDOWS:
        error("This command must be run from Windows")
        raise typer.Exit(1)

    # Determine remote username
    remote_user = user if user else os.environ.get("USERNAME", os.environ.get("USER", ""))
    if not remote_user:
        error("Could not determine username. Specify with --user")
        raise typer.Exit(1)

    # Find NVIDIA Sync key
    info("Looking for NVIDIA Sync key...")
    pubkey = get_nvidia_sync_pubkey()
    if not pubkey:
        warn("NVIDIA Sync key not found")
        info("NVIDIA Sync may not be installed or configured")
        info("Install from: https://www.nvidia.com/en-us/studio/software/")
        raise typer.Exit(1)

    ok(f"Found NVIDIA Sync key: {pubkey[:50]}...")

    # Check SSH connectivity to host
    info(f"Checking SSH connectivity to {host}...")
    success, output = ssh_to_host(host, "echo connected")
    if not success:
        error(f"Cannot SSH to {host}: {output}")
        info("Ensure you can SSH to the host with your regular key first")
        raise typer.Exit(1)

    ok(f"SSH to {host} works")

    # Ensure NVIDIA Sync key is authorized
    info(f"Ensuring NVIDIA Sync key is authorized on {host}...")
    if ensure_key_authorized(host, pubkey, "NVIDIA Sync"):
        ok("NVIDIA Sync key is authorized")
    else:
        error("Failed to authorize NVIDIA Sync key")
        raise typer.Exit(1)

    # Test NVIDIA Sync key specifically
    info("Testing NVIDIA Sync key connection...")
    appdata = os.environ.get("LOCALAPPDATA", "")
    key_path = Path(appdata) / "NVIDIA Corporation" / "Sync" / "config" / "nvsync.key"

    try:
        result = subprocess.run(
            [
                "ssh",
                "-i",
                str(key_path),
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                f"{remote_user}@{host}",
                "echo connected",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            ok("NVIDIA Sync key authentication works")
        else:
            warn(f"NVIDIA Sync key test failed: {result.stderr}")
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        warn(f"Could not test NVIDIA Sync key: {e}")

    section("Key Provisioning Complete")
    ok(f"NVIDIA Sync is authorized on {host}")
    info("You can now use NVIDIA Sync to connect to the remote host")


@app.command()
def status() -> None:
    """Check Windows mesh integration status."""
    section("Windows Mesh Status")

    os_type = detect_os_type()
    if os_type != OSType.WINDOWS:
        error("This command must be run from Windows")
        raise typer.Exit(1)

    # Check NVIDIA Sync
    info("Checking NVIDIA Sync...")
    pubkey = get_nvidia_sync_pubkey()
    if pubkey:
        ok("NVIDIA Sync key found")
    else:
        warn("NVIDIA Sync key not found")

    # Check SSHFS-Win
    info("Checking SSHFS-Win...")
    sshfs_path = Path("C:/Program Files/SSHFS-Win")
    if sshfs_path.exists():
        ok("SSHFS-Win installed")
    else:
        warn("SSHFS-Win not installed")

    # Check Tailscale
    info("Checking Tailscale...")
    tailscale_path = Path("C:/Program Files/Tailscale/tailscale.exe")
    if tailscale_path.exists():
        ok("Tailscale installed")
        try:
            result = subprocess.run(
                [str(tailscale_path), "status", "--json"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                import json

                status = json.loads(result.stdout)
                if status.get("BackendState") == "Running":
                    ok("Tailscale connected")
                else:
                    warn(f"Tailscale state: {status.get('BackendState', 'unknown')}")
        except Exception:
            warn("Could not check Tailscale status")
    else:
        warn("Tailscale not installed")

    # Check WSL
    info("Checking WSL...")
    try:
        result = subprocess.run(
            ["wsl", "-l", "-v"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if "Running" in result.stdout:
            ok("WSL is running")
        else:
            warn("WSL not running")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        warn("WSL not available")
