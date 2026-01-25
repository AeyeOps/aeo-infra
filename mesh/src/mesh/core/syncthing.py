"""Syncthing REST API client."""

import xml.etree.ElementTree as ET

import httpx

from mesh.core.config import get_syncthing_config_dir, get_syncthing_port


class SyncthingClient:
    """Client for interacting with Syncthing REST API."""

    def __init__(self, port: int | None = None) -> None:
        """Initialize with optional port override."""
        self.port = port or get_syncthing_port()
        self.base_url = f"http://localhost:{self.port}"
        self._api_key: str | None = None

    @property
    def api_key(self) -> str:
        """Get API key, loading from config if needed."""
        if self._api_key is None:
            self._api_key = self._load_api_key()
        return self._api_key

    def _load_api_key(self) -> str:
        """Extract API key from config."""
        config_dir = get_syncthing_config_dir()

        # Try api-key file first
        api_key_file = config_dir / "api-key"
        if api_key_file.exists():
            return api_key_file.read_text().strip()

        # Parse config.xml
        config_xml = config_dir / "config.xml"
        if config_xml.exists():
            tree = ET.parse(config_xml)
            apikey = tree.find(".//apikey")
            if apikey is not None and apikey.text:
                return apikey.text

        raise RuntimeError("Could not find Syncthing API key")

    def _headers(self) -> dict[str, str]:
        """Get headers with API key."""
        return {"X-API-Key": self.api_key}

    def is_running(self) -> bool:
        """Check if Syncthing is running."""
        try:
            resp = httpx.get(f"{self.base_url}/rest/system/ping", timeout=2)
            # 200 = OK, 403 = CSRF (running but needs auth)
            return resp.status_code in (200, 403)
        except httpx.RequestError:
            return False

    def get_device_id(self) -> str:
        """Get local device ID."""
        resp = httpx.get(
            f"{self.base_url}/rest/system/status",
            headers=self._headers(),
            timeout=5,
        )
        resp.raise_for_status()
        return resp.json()["myID"]

    def get_connections(self) -> dict:
        """Get connection status for all devices."""
        resp = httpx.get(
            f"{self.base_url}/rest/system/connections",
            headers=self._headers(),
            timeout=5,
        )
        resp.raise_for_status()
        return resp.json()

    def get_devices(self) -> list[dict]:
        """Get all configured devices."""
        resp = httpx.get(
            f"{self.base_url}/rest/config/devices",
            headers=self._headers(),
            timeout=5,
        )
        resp.raise_for_status()
        return resp.json()

    def add_device(self, device_id: str, name: str) -> None:
        """Add a new device."""
        resp = httpx.post(
            f"{self.base_url}/rest/config/devices",
            headers=self._headers(),
            json={"deviceID": device_id, "name": name},
            timeout=10,
        )
        resp.raise_for_status()

    def get_folders(self) -> list[dict]:
        """Get all configured folders."""
        resp = httpx.get(
            f"{self.base_url}/rest/config/folders",
            headers=self._headers(),
            timeout=5,
        )
        resp.raise_for_status()
        return resp.json()

    def share_folder(self, folder_id: str, device_id: str) -> None:
        """Share a folder with a device."""
        # Get current folder config
        resp = httpx.get(
            f"{self.base_url}/rest/config/folders/{folder_id}",
            headers=self._headers(),
            timeout=5,
        )
        resp.raise_for_status()
        folder = resp.json()

        # Add device if not already shared
        device_ids = [d["deviceID"] for d in folder.get("devices", [])]
        if device_id not in device_ids:
            folder.setdefault("devices", []).append({"deviceID": device_id})
            resp = httpx.put(
                f"{self.base_url}/rest/config/folders/{folder_id}",
                headers=self._headers(),
                json=folder,
                timeout=10,
            )
            resp.raise_for_status()
