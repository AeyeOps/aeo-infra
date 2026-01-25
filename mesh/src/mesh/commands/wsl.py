"""WSL2 provisioning commands (run from Windows to configure WSL)."""

import subprocess

import typer

from mesh.core.environment import OSType, detect_os_type
from mesh.utils.output import error, info, ok, section, warn

app = typer.Typer(
    name="wsl",
    help="WSL2 provisioning (run from Windows)",
    no_args_is_help=True,
)


def run_wsl(cmd: str, as_root: bool = False, distro: str | None = None) -> tuple[bool, str]:
    """Run a command inside WSL.

    Args:
        cmd: Command to run inside WSL
        as_root: Run as root user
        distro: Specific WSL distribution to use (None for default)
    """
    wsl_cmd = ["wsl"]
    if distro:
        wsl_cmd.extend(["-d", distro])
    if as_root:
        wsl_cmd.extend(["-u", "root"])
    wsl_cmd.extend(["-e", "bash", "-c", cmd])

    try:
        result = subprocess.run(
            wsl_cmd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        # Ignore fstab mount warnings
        stderr = result.stderr
        if "Processing /etc/fstab with mount -a failed" in stderr:
            stderr = ""
        return result.returncode == 0, result.stdout + stderr
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except FileNotFoundError:
        return False, "WSL not found"


def is_wsl_running() -> bool:
    """Check if WSL is running."""
    try:
        result = subprocess.run(
            ["wsl", "-l", "-v"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return "Running" in result.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


@app.command()
def setup_ssh(
    port: int = typer.Option(2222, "--port", "-p", help="SSH port to use"),
    copy_windows_keys: bool = typer.Option(
        True, "--copy-keys/--no-copy-keys", help="Copy Windows SSH authorized_keys to WSL"
    ),
    distro: str = typer.Option(
        "", "--distro", "-d", help="WSL distribution to use (default: system default)"
    ),
) -> None:
    """Install and configure SSH server in WSL2.

    This command:
    - Installs openssh-server in WSL
    - Configures it to listen on the specified port (default 2222)
    - Creates /run/sshd directory
    - Starts the SSH daemon
    - Optionally copies authorized_keys from Windows

    Note: Key copying assumes WSL username matches Windows username.
    Use --no-copy-keys if they differ.

    Idempotent: safe to run multiple times.
    """
    section("WSL2 SSH Setup")

    # Validate port range
    if not 1 <= port <= 65535:
        error(f"Invalid port {port}: must be between 1 and 65535")
        raise typer.Exit(1)

    os_type = detect_os_type()
    if os_type != OSType.WINDOWS:
        error("This command must be run from Windows")
        raise typer.Exit(1)

    if not is_wsl_running():
        error("WSL is not running")
        info("Start WSL with: wsl")
        raise typer.Exit(1)

    ok("WSL is running")

    # Create a wrapper for wsl with distro preset
    wsl_distro = distro if distro else None

    def run_cmd(cmd: str, as_root: bool = False) -> tuple[bool, str]:
        return run_wsl(cmd, as_root=as_root, distro=wsl_distro)

    # Check if SSH server is installed
    success, output = run_cmd("which sshd")
    if success and "/sshd" in output:
        ok("openssh-server already installed")
    else:
        info("Installing openssh-server...")
        # Update package list (suppress interactive prompts)
        run_cmd("DEBIAN_FRONTEND=noninteractive apt-get update -qq", as_root=True)
        success, output = run_cmd(
            "DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server",
            as_root=True,
        )
        if success or "openssh-server is already" in output:
            ok("openssh-server installed")
        else:
            error(f"Failed to install openssh-server: {output}")
            raise typer.Exit(1)

    # Create privilege separation directory
    info("Creating /run/sshd directory...")
    run_cmd("mkdir -p /run/sshd", as_root=True)
    ok("/run/sshd ready")

    # Configure SSH port
    info(f"Configuring SSH on port {port}...")
    # Check current port setting
    success, output = run_cmd(f"grep -E '^Port {port}$' /etc/ssh/sshd_config")
    if success:
        ok(f"SSH already configured for port {port}")
    else:
        # Update port configuration
        run_cmd(f"sed -i 's/^#Port 22$/Port {port}/' /etc/ssh/sshd_config", as_root=True)
        run_cmd(f"sed -i 's/^Port 22$/Port {port}/' /etc/ssh/sshd_config", as_root=True)
        # Verify
        success, _ = run_cmd(f"grep -E '^Port {port}$' /etc/ssh/sshd_config")
        if not success:
            # Port line doesn't exist, add it
            run_cmd(f"echo 'Port {port}' >> /etc/ssh/sshd_config", as_root=True)
        ok(f"SSH configured for port {port}")

    # Copy authorized_keys from Windows if requested
    if copy_windows_keys:
        info("Copying authorized_keys from Windows...")
        # Windows authorized_keys path (via WSL mount)
        win_keys = "/mnt/c/Users/$USER/.ssh/authorized_keys"
        wsl_ssh_dir = "/home/$USER/.ssh"

        success, output = run_cmd(
            f"""
            if [ -f {win_keys} ]; then
                mkdir -p {wsl_ssh_dir}
                # Append Windows keys if not already present
                while IFS= read -r key; do
                    if ! grep -qF "$key" {wsl_ssh_dir}/authorized_keys 2>/dev/null; then
                        echo "$key" >> {wsl_ssh_dir}/authorized_keys
                    fi
                done < {win_keys}
                chown -R $USER:$USER {wsl_ssh_dir}
                chmod 700 {wsl_ssh_dir}
                chmod 600 {wsl_ssh_dir}/authorized_keys
                echo "Keys copied"
            else
                echo "No Windows authorized_keys found"
            fi
        """,
            as_root=True,
        )
        if "Keys copied" in output:
            ok("Authorized keys copied from Windows")
        else:
            warn("No Windows authorized_keys to copy")

    # Check if sshd is already running on the port
    # Use word boundary to avoid matching port as part of larger number (e.g., :22 vs :2222)
    success, output = run_cmd(f"ss -tlnp 2>/dev/null | grep -E ':{port}\\b'")
    if success and f":{port}" in output:
        ok(f"SSH already listening on port {port}")
    else:
        # Start sshd
        info("Starting SSH daemon...")
        # Kill any existing sshd first
        run_cmd("pkill -9 sshd 2>/dev/null || true", as_root=True)
        success, output = run_cmd(f"/usr/sbin/sshd -p {port}", as_root=True)
        if success or output.strip() == "":
            # Verify it started
            success, output = run_cmd(f"ss -tlnp 2>/dev/null | grep -E ':{port}\\b'")
            if success:
                ok(f"SSH daemon started on port {port}")
            else:
                error("Failed to start SSH daemon")
                raise typer.Exit(1)
        else:
            error(f"Failed to start SSH daemon: {output}")
            raise typer.Exit(1)

    section("WSL SSH Setup Complete")
    ok(f"SSH server running on port {port}")
    info(f"Connect with: ssh -p {port} $USER@<windows-ip>")
    info("Note: SSH will stop when WSL shuts down. Run this command again after reboot.")


@app.command()
def status() -> None:
    """Check WSL2 SSH status."""
    section("WSL2 SSH Status")

    os_type = detect_os_type()
    if os_type != OSType.WINDOWS:
        error("This command must be run from Windows")
        raise typer.Exit(1)

    if not is_wsl_running():
        error("WSL is not running")
        raise typer.Exit(1)

    ok("WSL is running")

    # Check if sshd is installed
    success, _ = run_wsl("which sshd")
    if success:
        ok("openssh-server installed")
    else:
        warn("openssh-server not installed")
        info("Run: mesh wsl setup-ssh")
        return

    # Check if sshd is listening
    success, output = run_wsl("ss -tlnp 2>/dev/null | grep sshd")
    if success and "sshd" in output:
        # Extract port
        import re

        match = re.search(r":(\d+)\s", output)
        port = match.group(1) if match else "unknown"
        ok(f"SSH daemon running on port {port}")
    else:
        warn("SSH daemon not running")
        info("Run: mesh wsl setup-ssh")
