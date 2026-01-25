"""mDNS service discovery for mesh network servers."""

import socket
from typing import TYPE_CHECKING

from mesh.utils.output import error, info, warn

if TYPE_CHECKING:
    from zeroconf import Zeroconf

SERVICE_TYPE = "_mesh-headscale._tcp.local."
SERVICE_NAME = "mesh-headscale._mesh-headscale._tcp.local."


def advertise_server(port: int = 8080, hostname: str | None = None) -> "Zeroconf":
    """Advertise the mesh server via mDNS.

    Args:
        port: The port the Headscale server is running on.
        hostname: Override hostname for the service. Defaults to local hostname.

    Returns:
        The Zeroconf instance (keep reference to maintain advertisement).
        Call zeroconf.close() to stop advertising.
    """
    from zeroconf import ServiceInfo, Zeroconf

    if hostname is None:
        hostname = socket.gethostname()

    # Get local IP addresses
    local_ips = _get_local_ips()
    if not local_ips:
        raise RuntimeError("No local IP addresses found")

    zc = Zeroconf()

    service_info = ServiceInfo(
        type_=SERVICE_TYPE,
        name=SERVICE_NAME,
        port=port,
        properties={
            "version": "1",
            "hostname": hostname,
        },
        server=f"{hostname}.local.",
        addresses=[socket.inet_aton(ip) for ip in local_ips],
    )

    zc.register_service(service_info)
    info(f"Advertising mesh server on port {port}")
    for ip in local_ips:
        info(f"  Address: {ip}:{port}")

    return zc


def discover_server(timeout: float = 5.0) -> str | None:
    """Discover a mesh server on the local network via mDNS.

    Args:
        timeout: How long to wait for discovery in seconds.

    Returns:
        Server URL (e.g., "http://192.168.1.10:8080") or None if not found.
    """
    try:
        from zeroconf import ServiceBrowser, ServiceListener, Zeroconf
    except ImportError:
        error("zeroconf not installed - run: uv add zeroconf")
        return None

    class Listener(ServiceListener):
        def __init__(self) -> None:
            self.server_url: str | None = None

        def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            info_obj = zc.get_service_info(type_, name)
            if info_obj:
                addresses = info_obj.parsed_addresses()
                if addresses:
                    ip = addresses[0]
                    port = info_obj.port
                    self.server_url = f"http://{ip}:{port}"

        def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            pass

        def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            pass

    try:
        zc = Zeroconf()
        listener = Listener()
        browser = ServiceBrowser(zc, SERVICE_TYPE, listener)

        # Wait for discovery
        import time

        start = time.time()
        while listener.server_url is None and (time.time() - start) < timeout:
            time.sleep(0.1)

        browser.cancel()
        zc.close()

        return listener.server_url

    except OSError as e:
        warn(f"Discovery failed: {e}")
        info("Ensure UDP port 5353 is open for mDNS")
        return None


def _get_local_ips() -> list[str]:
    """Get local IP addresses (excluding loopback)."""
    ips = []
    try:
        # Get all network interfaces
        hostname = socket.gethostname()
        # Try to get all addresses for this host
        addrs = socket.getaddrinfo(hostname, None, socket.AF_INET)
        for addr in addrs:
            ip = addr[4][0]
            if not ip.startswith("127."):
                ips.append(ip)
    except socket.gaierror:
        pass

    # Fallback: try to connect to external address to find local IP
    if not ips:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            if not ip.startswith("127."):
                ips.append(ip)
        except Exception:
            pass

    return ips
