"""SSH configuration management."""

import subprocess
from pathlib import Path

# Default timeout buffer added to SSH ConnectTimeout
SSH_TIMEOUT_BUFFER = 5


def ssh_to_host(host: str, cmd: str, timeout: int = 30, port: int = 22) -> tuple[bool, str]:
    """Run a command on a remote host via SSH.

    Args:
        host: Remote hostname or user@host
        cmd: Command to execute on remote host
        timeout: SSH connection timeout in seconds
        port: SSH port (default 22)

    Returns:
        Tuple of (success, output) where output is stdout+stderr
    """
    try:
        result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={timeout}",
             "-p", str(port), host, cmd],
            capture_output=True,
            text=True,
            timeout=timeout + SSH_TIMEOUT_BUFFER,
        )
        return result.returncode == 0, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return False, "SSH connection timed out"
    except FileNotFoundError:
        return False, "SSH client not found"


SSH_CONFIG_MARKER = "# Mesh network hosts - managed by mesh CLI"
SSH_CONFIG_END = "# End mesh network hosts"

MESH_SSH_CONFIG = """
# Mesh network hosts - managed by mesh CLI
Host sfspark1
    HostName sfspark1.local
    User steve
    Port 22

Host office-one-wsl
    HostName office-one.local
    User steve
    Port 2222

Host office-one-windows
    HostName office-one.local
    User steve
    Port 22
# End mesh network hosts
"""


def get_ssh_config_path() -> Path:
    """Get SSH config file path."""
    return Path.home() / ".ssh" / "config"


def has_mesh_config() -> bool:
    """Check if mesh SSH config is already present."""
    config_path = get_ssh_config_path()
    if not config_path.exists():
        return False
    content = config_path.read_text()
    return SSH_CONFIG_MARKER in content


def add_mesh_config() -> bool:
    """Add mesh SSH config to user's SSH config."""
    config_path = get_ssh_config_path()

    # Ensure .ssh directory exists
    config_path.parent.mkdir(mode=0o700, exist_ok=True)

    # Read existing config
    existing = ""
    if config_path.exists():
        existing = config_path.read_text()

    # Check if already present
    if SSH_CONFIG_MARKER in existing:
        return True  # Already configured

    # Prepend mesh config
    new_content = MESH_SSH_CONFIG.strip() + "\n\n" + existing
    config_path.write_text(new_content)
    config_path.chmod(0o600)
    return True


def remove_mesh_config() -> bool:
    """Remove mesh SSH config from user's SSH config."""
    config_path = get_ssh_config_path()
    if not config_path.exists():
        return True

    content = config_path.read_text()
    if SSH_CONFIG_MARKER not in content:
        return True  # Not present

    # Remove the mesh config block
    lines = content.split("\n")
    new_lines = []
    in_mesh_block = False

    for line in lines:
        if SSH_CONFIG_MARKER in line:
            in_mesh_block = True
            continue
        if SSH_CONFIG_END in line:
            in_mesh_block = False
            continue
        if not in_mesh_block:
            new_lines.append(line)

    # Remove leading blank lines
    while new_lines and not new_lines[0].strip():
        new_lines.pop(0)

    config_path.write_text("\n".join(new_lines))
    return True


# --- Dynamic Host Management ---
# These functions manage individual hosts with markers like:
#   # mesh-managed: ubu1
#   Host ubu1
#       HostName 192.168.50.10
#       Port 22
#       User steve
#   # end mesh-managed: ubu1

DYNAMIC_HOST_START = "# mesh-managed:"
DYNAMIC_HOST_END = "# end mesh-managed:"


def host_exists(name: str) -> bool:
    """Check if a host entry exists in SSH config (static or dynamic).

    Args:
        name: Hostname to check

    Returns:
        True if host entry exists.
    """
    config_path = get_ssh_config_path()
    if not config_path.exists():
        return False

    content = config_path.read_text()
    # Check for dynamic marker
    if f"{DYNAMIC_HOST_START} {name}" in content:
        return True
    # Check for Host directive (catches static entries too)
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped.lower().startswith("host "):
            hosts = stripped[5:].split()
            if name in hosts:
                return True
    return False


def add_ssh_host(name: str, hostname: str, port: int = 22, user: str = "steve") -> bool:
    """Add or update a dynamic SSH host entry.

    Args:
        name: Host alias (e.g., "ubu1")
        hostname: Actual hostname or IP (e.g., "192.168.50.10")
        port: SSH port
        user: SSH username

    Returns:
        True on success.
    """
    config_path = get_ssh_config_path()
    config_path.parent.mkdir(mode=0o700, exist_ok=True)

    # Read existing config
    existing = ""
    if config_path.exists():
        existing = config_path.read_text()

    # Remove existing dynamic entry for this host if present
    existing = _remove_dynamic_host_block(existing, name)

    # Build new entry
    entry = f"""
{DYNAMIC_HOST_START} {name}
Host {name}
    HostName {hostname}
    Port {port}
    User {user}
{DYNAMIC_HOST_END} {name}
"""

    # Append to config
    new_content = existing.rstrip() + "\n" + entry.strip() + "\n"
    config_path.write_text(new_content)
    config_path.chmod(0o600)
    return True


def remove_ssh_host(name: str) -> bool:
    """Remove a dynamic SSH host entry.

    Args:
        name: Host alias to remove

    Returns:
        True if host was removed, False if not found.
    """
    config_path = get_ssh_config_path()
    if not config_path.exists():
        return False

    content = config_path.read_text()
    marker = f"{DYNAMIC_HOST_START} {name}"
    if marker not in content:
        return False

    new_content = _remove_dynamic_host_block(content, name)
    config_path.write_text(new_content)
    return True


def _remove_dynamic_host_block(content: str, name: str) -> str:
    """Remove a dynamic host block from SSH config content.

    Args:
        content: SSH config content
        name: Hostname to remove

    Returns:
        Content with the host block removed.
    """
    start_marker = f"{DYNAMIC_HOST_START} {name}"
    end_marker = f"{DYNAMIC_HOST_END} {name}"

    lines = content.split("\n")
    new_lines = []
    in_block = False

    for line in lines:
        if start_marker in line:
            in_block = True
            continue
        if end_marker in line:
            in_block = False
            continue
        if not in_block:
            new_lines.append(line)

    # Clean up extra blank lines
    result = "\n".join(new_lines)
    while "\n\n\n" in result:
        result = result.replace("\n\n\n", "\n\n")
    return result.strip() + "\n" if result.strip() else ""
