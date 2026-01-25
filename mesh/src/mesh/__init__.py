"""Mesh network setup tools (Headscale + Syncthing)."""

from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("mesh")
except PackageNotFoundError:
    __version__ = "0.0.0.dev"
