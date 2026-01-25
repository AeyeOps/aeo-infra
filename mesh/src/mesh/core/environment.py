"""Environment detection for OS type and machine role."""

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

    SFSPARK1 = "sfspark1"
    WSL2 = "wsl2"
    WINDOWS = "windows"
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


def detect_role() -> Role:
    """Detect machine role based on hostname."""
    hostname = socket.gethostname().lower()
    os_type = detect_os_type()

    if hostname in ("sfspark1", "sfspark1.local"):
        return Role.SFSPARK1
    elif hostname == "office-one":
        return Role.WSL2 if os_type == OSType.WSL2 else Role.WINDOWS
    return Role.UNKNOWN


def get_hostname() -> str:
    """Get the current hostname."""
    return socket.gethostname()
