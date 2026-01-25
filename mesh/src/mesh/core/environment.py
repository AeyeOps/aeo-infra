"""Environment detection for OS type and machine role."""

import os
import platform
import socket
from enum import Enum
from pathlib import Path


class OSType(Enum):
    """Operating system type."""

    UBUNTU = "ubuntu"
    WSL2 = "wsl2"
    WINDOWS = "windows"
    MACOS = "macos"
    UNKNOWN = "unknown"


class Role(Enum):
    """Machine role in the mesh network."""

    SERVER = "server"  # Headscale coordination server
    WSL2 = "wsl2"  # WSL2 client
    WINDOWS = "windows"  # Windows client
    UNKNOWN = "unknown"


def detect_os_type() -> OSType:
    """Detect operating system type."""
    # Check for WSL2 first (before generic Linux check)
    if Path("/proc/version").exists():
        content = Path("/proc/version").read_text().lower()
        if "microsoft" in content:
            return OSType.WSL2

    system = platform.system().lower()
    os_map = {
        "windows": OSType.WINDOWS,
        "darwin": OSType.MACOS,
        "linux": OSType.UBUNTU,
    }
    return os_map.get(system, OSType.UNKNOWN)


def _get_role_config() -> dict[str, Role]:
    """Get hostname-to-role mapping from environment.

    Reads from environment variables:
    - MESH_SERVER_HOSTNAMES: Comma-separated hostnames that are servers
    - MESH_WSL2_HOSTNAMES: Comma-separated hostnames that are WSL2 clients
    - MESH_WINDOWS_HOSTNAMES: Comma-separated hostnames that are Windows clients

    Returns:
        Dict mapping lowercase hostname to Role.
    """
    config: dict[str, Role] = {}

    # Parse server hostnames
    server_hosts = os.environ.get("MESH_SERVER_HOSTNAMES", "")
    for host in server_hosts.split(","):
        host = host.strip().lower()
        if host:
            config[host] = Role.SERVER

    # Parse WSL2 hostnames
    wsl2_hosts = os.environ.get("MESH_WSL2_HOSTNAMES", "")
    for host in wsl2_hosts.split(","):
        host = host.strip().lower()
        if host:
            config[host] = Role.WSL2

    # Parse Windows hostnames
    windows_hosts = os.environ.get("MESH_WINDOWS_HOSTNAMES", "")
    for host in windows_hosts.split(","):
        host = host.strip().lower()
        if host:
            config[host] = Role.WINDOWS

    return config


def detect_role() -> Role:
    """Detect machine role based on hostname and configuration.

    Role detection priority:
    1. Environment variable configuration (MESH_*_HOSTNAMES)
    2. OS-based inference for WSL2/Windows (if hostname matches a configured client)
    3. UNKNOWN if no match

    For multi-machine setups, configure hostnames via environment:
        MESH_SERVER_HOSTNAMES=myserver,myserver.local
        MESH_WSL2_HOSTNAMES=myclient
        MESH_WINDOWS_HOSTNAMES=myclient

    Note: WSL2 and Windows often share a hostname. The OS type is used
    to distinguish them when the hostname is configured in both.
    """
    hostname = socket.gethostname().lower()
    os_type = detect_os_type()

    # Check configured mappings
    config = _get_role_config()

    # Direct hostname match
    if hostname in config:
        role = config[hostname]
        # For shared hostnames (WSL2/Windows on same machine), use OS to disambiguate
        if role in (Role.WSL2, Role.WINDOWS):
            if os_type == OSType.WSL2:
                return Role.WSL2
            elif os_type == OSType.WINDOWS:
                return Role.WINDOWS
        return role

    # Check if hostname is in multiple role configs (shared WSL2/Windows hostname)
    # This handles the case where a hostname appears in both MESH_WSL2_HOSTNAMES
    # and MESH_WINDOWS_HOSTNAMES for a machine running both
    all_client_hosts = set()
    wsl2_hosts = os.environ.get("MESH_WSL2_HOSTNAMES", "").lower().split(",")
    windows_hosts = os.environ.get("MESH_WINDOWS_HOSTNAMES", "").lower().split(",")
    all_client_hosts.update(h.strip() for h in wsl2_hosts if h.strip())
    all_client_hosts.update(h.strip() for h in windows_hosts if h.strip())

    if hostname in all_client_hosts:
        if os_type == OSType.WSL2:
            return Role.WSL2
        elif os_type == OSType.WINDOWS:
            return Role.WINDOWS

    # No configuration found - if we're on WSL2 or Windows, return that role
    # This provides sensible defaults for simple setups
    if os_type == OSType.WSL2:
        return Role.WSL2
    elif os_type == OSType.WINDOWS:
        return Role.WINDOWS

    # For Linux servers, check if we might be the server
    # (only if MESH_SERVER_HOSTNAMES is not set, indicating no explicit config)
    if os_type == OSType.UBUNTU and not os.environ.get("MESH_SERVER_HOSTNAMES"):
        # No config at all - could be the server
        # Return UNKNOWN to be safe; user should configure explicitly
        return Role.UNKNOWN

    return Role.UNKNOWN


def is_server() -> bool:
    """Check if current machine is the coordination server."""
    return detect_role() == Role.SERVER


def get_hostname() -> str:
    """Get the current hostname."""
    return socket.gethostname()
