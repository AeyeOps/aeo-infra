"""Configuration paths and settings management."""

import os
import re
from dataclasses import dataclass
from pathlib import Path

import yaml

from mesh.core.environment import OSType, Role, detect_os_type, detect_role


def get_syncthing_config_dir() -> Path:
    """Get Syncthing config directory based on OS type."""
    os_type = detect_os_type()
    if os_type == OSType.WINDOWS:
        return Path(os.environ.get("LOCALAPPDATA", "")) / "Syncthing"

    # Modern Syncthing (1.27+) uses XDG_STATE_HOME, fallback to legacy location
    state_dir = Path.home() / ".local" / "state" / "syncthing"
    if state_dir.exists():
        return state_dir
    return Path.home() / ".config" / "syncthing"


def get_syncthing_port() -> int:
    """Get Syncthing GUI port based on role."""
    role = detect_role()
    ports = {
        Role.SFSPARK1: 8384,
        Role.WSL2: 8385,
        Role.WINDOWS: 8386,
    }
    return ports.get(role, 8384)


def get_syncthing_sync_port() -> int:
    """Get Syncthing sync port based on role."""
    role = detect_role()
    ports = {
        Role.SFSPARK1: 22000,
        Role.WSL2: 22001,
        Role.WINDOWS: 22002,
    }
    return ports.get(role, 22000)


def get_mesh_config_dir() -> Path:
    """Get mesh CLI config directory."""
    config_dir = Path.home() / ".config" / "mesh"
    config_dir.mkdir(parents=True, exist_ok=True)
    return config_dir


def get_headscale_server() -> str | None:
    """Get saved Headscale server URL."""
    config_file = get_mesh_config_dir() / "headscale-server"
    if config_file.exists():
        return config_file.read_text().strip()
    return None


def save_headscale_server(url: str) -> None:
    """Save Headscale server URL."""
    config_file = get_mesh_config_dir() / "headscale-server"
    config_file.write_text(url)


def get_shared_folder() -> Path:
    """Get the shared folder path based on OS type."""
    os_type = detect_os_type()
    if os_type == OSType.WINDOWS:
        return Path("C:/shared")
    return Path("/opt/shared")


# --- Host Registry ---


@dataclass
class Host:
    """A registered mesh host."""

    name: str
    ip: str
    port: int = 22
    user: str = "steve"


def _get_hosts_file() -> Path:
    """Get path to hosts.yaml registry file."""
    return get_mesh_config_dir() / "hosts.yaml"


def load_hosts() -> dict[str, Host]:
    """Load hosts from ~/.config/mesh/hosts.yaml.

    Returns:
        Dict mapping hostname to Host object.
    """
    hosts_file = _get_hosts_file()
    if not hosts_file.exists():
        return {}

    try:
        data = yaml.safe_load(hosts_file.read_text()) or {}
        hosts_data = data.get("hosts", {}) or {}
        result = {}
        for name, info in hosts_data.items():
            # Skip malformed entries (null or non-dict values)
            if not isinstance(info, dict):
                continue
            result[name] = Host(
                name=name,
                ip=info.get("ip", ""),
                port=info.get("port", 22),
                user=info.get("user", "steve"),
            )
        return result
    except yaml.YAMLError:
        return {}


def save_hosts(hosts: dict[str, Host]) -> None:
    """Save hosts to ~/.config/mesh/hosts.yaml."""
    hosts_file = _get_hosts_file()
    data = {
        "hosts": {
            host.name: {
                "ip": host.ip,
                "port": host.port,
                "user": host.user,
            }
            for host in hosts.values()
        }
    }
    hosts_file.write_text(yaml.dump(data, default_flow_style=False, sort_keys=False))


# Valid hostname: alphanumeric, hyphens, underscores (no spaces or special chars)
VALID_HOSTNAME_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$")


def validate_hostname(name: str) -> bool:
    """Validate hostname for use in SSH config.

    Args:
        name: Hostname to validate

    Returns:
        True if valid, False otherwise.
    """
    if not name or len(name) > 63:
        return False
    return bool(VALID_HOSTNAME_PATTERN.match(name))


class InvalidHostnameError(ValueError):
    """Raised when hostname contains invalid characters."""

    pass


def add_host(name: str, ip: str, port: int = 22, user: str = "steve") -> Host:
    """Add or update a host in the registry. Idempotent.

    Args:
        name: Hostname (e.g., "ubu1")
        ip: IP address or hostname (e.g., "192.168.50.10")
        port: SSH port (default 22)
        user: SSH username (default "steve")

    Returns:
        The created or updated Host.

    Raises:
        InvalidHostnameError: If hostname contains invalid characters.
    """
    if not validate_hostname(name):
        raise InvalidHostnameError(
            f"Invalid hostname '{name}': must be alphanumeric with hyphens/underscores, "
            "start with letter/number, max 63 chars"
        )

    hosts = load_hosts()
    host = Host(name=name, ip=ip, port=port, user=user)
    hosts[name] = host
    save_hosts(hosts)
    return host


def remove_host(name: str) -> bool:
    """Remove a host from the registry.

    Args:
        name: Hostname to remove

    Returns:
        True if host was removed, False if not found.
    """
    hosts = load_hosts()
    if name not in hosts:
        return False
    del hosts[name]
    save_hosts(hosts)
    return True


def get_host(name: str) -> Host | None:
    """Get a host from the registry.

    Args:
        name: Hostname to look up

    Returns:
        Host if found, None otherwise.
    """
    hosts = load_hosts()
    return hosts.get(name)
