"""Ubuntu provisioning commands (run on target Ubuntu machine)."""

import subprocess
from pathlib import Path

import typer

from mesh.core.environment import OSType, detect_os_type
from mesh.utils.output import error, info, ok, section, warn
from mesh.utils.process import command_exists, run_sudo
from mesh.utils.ssh import ssh_to_host

app = typer.Typer(
    name="ubuntu",
    help="Ubuntu provisioning commands",
    no_args_is_help=True,
)


def is_sshd_installed() -> bool:
    """Check if openssh-server is installed."""
    return command_exists("sshd")


def is_sshd_running() -> bool:
    """Check if sshd is running."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "ssh"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() == "active"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def get_sshd_port() -> int | None:
    """Get the configured SSH port."""
    config_path = Path("/etc/ssh/sshd_config")
    if not config_path.exists():
        return None

    try:
        content = config_path.read_text()
        for line in content.splitlines():
            line = line.strip()
            if line.startswith("Port "):
                return int(line.split()[1])
        return 22  # Default port if not specified
    except (ValueError, IndexError, PermissionError):
        return None


def get_authorized_keys_path() -> Path:
    """Get the path to authorized_keys file."""
    return Path.home() / ".ssh" / "authorized_keys"


@app.command()
def setup_ssh(
    port: int = typer.Option(22, "--port", "-p", help="SSH port to use"),
    password_auth: bool = typer.Option(
        False, "--password-auth/--no-password-auth", help="Allow password authentication"
    ),
) -> None:
    """Install and configure SSH server on Ubuntu.

    This command:
    - Installs openssh-server if not present
    - Configures the SSH port
    - Optionally disables password authentication
    - Ensures sshd is running

    Idempotent: safe to run multiple times.
    """
    section("Ubuntu SSH Setup")

    # Validate port range
    if not 1 <= port <= 65535:
        error(f"Invalid port {port}: must be between 1 and 65535")
        raise typer.Exit(1)

    os_type = detect_os_type()
    if os_type not in (OSType.UBUNTU, OSType.WSL2):
        warn(f"This command is designed for Ubuntu, detected: {os_type.value}")
        info("Continuing anyway...")

    # Check if SSH server is installed
    if is_sshd_installed():
        ok("openssh-server already installed")
    else:
        info("Installing openssh-server...")
        result = run_sudo(
            ["apt-get", "update"],
            env={"DEBIAN_FRONTEND": "noninteractive"},
        )
        result = run_sudo(
            ["apt-get", "install", "-y", "openssh-server"],
            env={"DEBIAN_FRONTEND": "noninteractive"},
        )
        if result.success:
            ok("openssh-server installed")
        else:
            error(f"Failed to install openssh-server: {result.stderr}")
            raise typer.Exit(1)

    # Configure SSH port
    current_port = get_sshd_port()
    if current_port == port:
        ok(f"SSH already configured for port {port}")
    else:
        info(f"Configuring SSH on port {port}...")
        # Update port in sshd_config
        run_sudo(["sed", "-i", f"s/^#Port 22$/Port {port}/", "/etc/ssh/sshd_config"])
        run_sudo(["sed", "-i", f"s/^Port [0-9]*$/Port {port}/", "/etc/ssh/sshd_config"])
        ok(f"SSH configured for port {port}")

    # Configure password authentication
    if not password_auth:
        info("Disabling password authentication...")
        run_sudo(
            [
                "sed",
                "-i",
                "s/^#PasswordAuthentication yes$/PasswordAuthentication no/",
                "/etc/ssh/sshd_config",
            ]
        )
        run_sudo(
            [
                "sed",
                "-i",
                "s/^PasswordAuthentication yes$/PasswordAuthentication no/",
                "/etc/ssh/sshd_config",
            ]
        )
        ok("Password authentication disabled")
    else:
        info("Keeping password authentication enabled")

    # Ensure .ssh directory exists
    ssh_dir = Path.home() / ".ssh"
    if not ssh_dir.exists():
        ssh_dir.mkdir(mode=0o700)
        ok("Created ~/.ssh directory")

    # Restart sshd to apply changes
    info("Restarting SSH service...")
    result = run_sudo(["systemctl", "restart", "ssh"])
    if result.success:
        ok("SSH service restarted")
    else:
        # Try sshd service name (some distros use this)
        result = run_sudo(["systemctl", "restart", "sshd"])
        if result.success:
            ok("SSH service restarted")
        else:
            warn("Could not restart SSH service")

    # Enable SSH service
    run_sudo(["systemctl", "enable", "ssh"])

    # Verify it's running
    if is_sshd_running():
        ok("SSH server is running")
    else:
        warn("SSH server may not be running - check with: systemctl status ssh")

    section("SSH Setup Complete")
    info(f"SSH server running on port {port}")
    if not password_auth:
        info("Password auth disabled - ensure you have keys in ~/.ssh/authorized_keys")


@app.command()
def copy_keys(
    source_host: str = typer.Option(..., "--from", "-f", help="Host to copy authorized_keys from"),
    merge: bool = typer.Option(
        True, "--merge/--replace", help="Merge with existing keys (default) or replace"
    ),
) -> None:
    """Copy authorized_keys from another host.

    This command:
    - Connects to the source host via SSH
    - Fetches its authorized_keys
    - Merges (or replaces) local authorized_keys

    Requires existing SSH access to the source host.
    """
    section("Copy Authorized Keys")

    # Check SSH connectivity to source
    info(f"Checking SSH connectivity to {source_host}...")
    success, output = ssh_to_host(source_host, "echo connected")
    if not success:
        error(f"Cannot SSH to {source_host}: {output}")
        info("Ensure you can SSH to the source host first")
        raise typer.Exit(1)

    ok(f"Connected to {source_host}")

    # Fetch authorized_keys from source
    info("Fetching authorized_keys from source...")
    success, output = ssh_to_host(source_host, "cat ~/.ssh/authorized_keys 2>/dev/null || true")
    if not success:
        error(f"Failed to fetch keys: {output}")
        raise typer.Exit(1)

    source_keys = [line.strip() for line in output.strip().splitlines() if line.strip()]
    if not source_keys:
        warn("No authorized_keys found on source host")
        raise typer.Exit(1)

    ok(f"Found {len(source_keys)} key(s) on source")

    # Ensure .ssh directory exists
    ssh_dir = Path.home() / ".ssh"
    ssh_dir.mkdir(mode=0o700, exist_ok=True)

    auth_keys_path = get_authorized_keys_path()

    if merge and auth_keys_path.exists():
        # Read existing keys
        existing_keys = set(auth_keys_path.read_text().strip().splitlines())
        # Merge
        all_keys = existing_keys | set(source_keys)
        new_count = len(all_keys) - len(existing_keys)
        auth_keys_path.write_text("\n".join(sorted(all_keys)) + "\n")
        auth_keys_path.chmod(0o600)
        ok(f"Merged keys - added {new_count} new key(s)")
    else:
        # Replace
        auth_keys_path.write_text("\n".join(source_keys) + "\n")
        auth_keys_path.chmod(0o600)
        ok(f"Replaced authorized_keys with {len(source_keys)} key(s)")

    section("Key Copy Complete")
    info(f"Keys copied from {source_host}")


@app.command()
def add_key(
    key: str = typer.Argument(..., help="Public key string or path to .pub file"),
    comment: str = typer.Option("", "--comment", "-c", help="Optional comment for the key"),
) -> None:
    """Add a public key to authorized_keys.

    Accepts either a key string or path to a .pub file.
    Idempotent: won't add duplicate keys.
    """
    section("Add SSH Key")

    # Check if key is a file path
    key_path = Path(key)
    if key_path.exists():
        info(f"Reading key from {key_path}...")
        pubkey = key_path.read_text().strip()
    else:
        pubkey = key.strip()

    # Validate it looks like a public key
    if not pubkey.startswith(("ssh-", "ecdsa-", "sk-")):
        error("Invalid public key format")
        info("Key should start with ssh-rsa, ssh-ed25519, ecdsa-sha2, etc.")
        raise typer.Exit(1)

    # Add comment if provided
    if comment:
        # Check if key already has a comment (3rd field)
        parts = pubkey.split()
        if len(parts) >= 2:
            pubkey = f"{parts[0]} {parts[1]} {comment}"

    # Ensure .ssh directory exists
    ssh_dir = Path.home() / ".ssh"
    ssh_dir.mkdir(mode=0o700, exist_ok=True)

    auth_keys_path = get_authorized_keys_path()

    # Check if key already exists
    try:
        if auth_keys_path.exists():
            existing = auth_keys_path.read_text()
            # Check by key body (2nd field) to avoid comment mismatches
            key_body = pubkey.split()[1] if len(pubkey.split()) >= 2 else pubkey
            if key_body in existing:
                ok("Key already exists in authorized_keys")
                return
    except PermissionError:
        error(f"Permission denied reading {auth_keys_path}")
        info(f"Check permissions with: ls -la {auth_keys_path}")
        raise typer.Exit(1) from None

    # Append key
    try:
        with auth_keys_path.open("a") as f:
            f.write(pubkey + "\n")
        auth_keys_path.chmod(0o600)
    except PermissionError:
        error(f"Permission denied writing to {auth_keys_path}")
        info(f"Check permissions with: ls -la {auth_keys_path.parent}")
        raise typer.Exit(1) from None

    ok("Key added to authorized_keys")


@app.command()
def status() -> None:
    """Check Ubuntu SSH and mesh readiness status."""
    section("Ubuntu Status")

    os_type = detect_os_type()
    info(f"OS type: {os_type.value}")

    # Check SSH server
    info("Checking SSH server...")
    if is_sshd_installed():
        ok("openssh-server installed")
        if is_sshd_running():
            port = get_sshd_port()
            ok(f"SSH server running on port {port or 'unknown'}")
        else:
            warn("SSH server not running")
            info("Start with: sudo systemctl start ssh")
    else:
        warn("openssh-server not installed")
        info("Install with: mesh ubuntu setup-ssh")

    # Check authorized_keys
    info("Checking authorized_keys...")
    auth_keys = get_authorized_keys_path()
    if auth_keys.exists():
        keys = [line for line in auth_keys.read_text().splitlines() if line.strip()]
        ok(f"authorized_keys has {len(keys)} key(s)")
    else:
        warn("No authorized_keys file")
        info("Add keys with: mesh ubuntu add-key <key>")

    # Check firewall
    info("Checking firewall...")
    if command_exists("ufw"):
        try:
            result = subprocess.run(
                ["ufw", "status"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if "inactive" in result.stdout.lower():
                info("UFW firewall is inactive")
            elif "active" in result.stdout.lower():
                ok("UFW firewall is active")
                # Check if SSH is allowed
                if "22" in result.stdout or "ssh" in result.stdout.lower():
                    ok("SSH allowed through firewall")
                else:
                    warn("SSH may not be allowed through firewall")
                    info("Allow with: sudo ufw allow ssh")
        except (subprocess.TimeoutExpired, FileNotFoundError):
            info("Could not check UFW status")
    else:
        info("UFW not installed")

    # Check Tailscale
    info("Checking Tailscale...")
    if command_exists("tailscale"):
        ok("Tailscale installed")
        try:
            result = subprocess.run(
                ["tailscale", "status", "--json"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                import json

                status_data = json.loads(result.stdout)
                state = status_data.get("BackendState", "unknown")
                if state == "Running":
                    ok("Tailscale connected")
                else:
                    warn(f"Tailscale state: {state}")
        except Exception:
            warn("Could not check Tailscale status")
    else:
        info("Tailscale not installed")
        info("Install with: mesh client setup")

    # Check Syncthing
    info("Checking Syncthing...")
    if command_exists("syncthing"):
        ok("Syncthing installed")
    else:
        info("Syncthing not installed")
        info("Install with: mesh client setup")
