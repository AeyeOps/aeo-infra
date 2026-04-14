"""Privacy validation for mesh network hardening.

Checks DERP relay privacy, logtail suppression, DNS acceptance,
and Headscale configuration hardening.
"""

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from mesh.core.environment import OSType, detect_os_type
from mesh.utils.process import run

# --- Dataclasses ---


@dataclass
class DerpStatus:
    """Status of DERP relay privacy."""

    is_private: bool
    regions: list[dict] = field(default_factory=list)
    public_regions: list[str] = field(default_factory=list)
    error: str | None = None

    def summary(self) -> str:
        """Human-readable one-liner."""
        if self.error:
            return f"DERP: error ({self.error})"
        if self.is_private:
            count = len(self.regions)
            label = "region" if count == 1 else "regions"
            return f"DERP: private only ({count} {label})"
        count = len(self.public_regions)
        label = "region" if count == 1 else "regions"
        return f"DERP: {count} public {label} detected"


@dataclass
class LogtailStatus:
    """Status of Tailscale logtail suppression."""

    suppressed: bool
    file_path: str
    file_exists: bool
    error: str | None = None

    def summary(self) -> str:
        """Human-readable one-liner."""
        if self.error:
            return f"Logtail: error ({self.error})"
        if self.suppressed:
            return f"Logtail: suppressed ({self.file_path})"
        if not self.file_exists:
            return f"Logtail: not suppressed (file missing: {self.file_path})"
        return f"Logtail: not suppressed ({self.file_path})"


@dataclass
class DnsStatus:
    """Status of DNS acceptance configuration."""

    accept_dns: bool | None
    raw_prefs: dict | None = None
    error: str | None = None

    def summary(self) -> str:
        """Human-readable one-liner."""
        if self.error:
            return f"DNS: error ({self.error})"
        if self.accept_dns is None:
            return "DNS: unknown (could not determine)"
        if self.accept_dns:
            return "DNS: accept-dns enabled"
        return "DNS: accept-dns disabled"


@dataclass
class HeadscaleConfigStatus:
    """Status of Headscale configuration hardening."""

    config_exists: bool
    derp_server_enabled: bool
    public_derp_urls_empty: bool
    logtail_disabled: bool
    dns_override_disabled: bool
    listen_loopback_only: bool
    is_hardened: bool
    error: str | None = None

    def summary(self) -> str:
        """Human-readable one-liner."""
        if self.error:
            return f"Config: error ({self.error})"
        if not self.config_exists:
            return "Config: file not found"
        if self.is_hardened:
            return "Config: hardened"
        checks = {
            "derp_server_enabled": self.derp_server_enabled,
            "public_derp_urls_empty": self.public_derp_urls_empty,
            "logtail_disabled": self.logtail_disabled,
            "dns_override_disabled": self.dns_override_disabled,
            "listen_loopback_only": self.listen_loopback_only,
        }
        failing = sum(1 for v in checks.values() if not v)
        return f"Config: {failing} of 5 checks failing"


# --- Check functions ---


def check_derp_map() -> DerpStatus:
    """Check DERP relay map for public regions.

    Runs ``tailscale debug derp-map`` and inspects the resulting JSON.
    Public Tailscale DERP regions use IDs 1-99; private ones are typically 900+.
    """
    try:
        result = run(["tailscale", "debug", "derp-map"], timeout=10)
        if not result.success:
            return DerpStatus(
                is_private=False,
                error=f"tailscale debug derp-map failed: {result.stderr.strip()}",
            )

        data = json.loads(result.stdout)
        regions_raw = data.get("Regions", {})

        regions: list[dict] = []
        public_regions: list[str] = []

        for region_id_str, region in regions_raw.items():
            region_id = int(region_id_str)
            nodes = region.get("Nodes", []) or []
            hostname = nodes[0].get("HostName", "") if nodes else ""

            regions.append(
                {
                    "id": region_id,
                    "name": region.get("RegionName", ""),
                    "hostname": hostname,
                }
            )

            # Public Tailscale DERP: IDs 1-99 or hostnames containing tailscale.com
            is_public = region_id < 100 or any(
                "tailscale.com" in (n.get("HostName", "") or "")
                for n in nodes
            )
            if is_public:
                public_regions.append(hostname or f"region-{region_id}")

        return DerpStatus(
            is_private=len(public_regions) == 0,
            regions=regions,
            public_regions=public_regions,
        )

    except json.JSONDecodeError as exc:
        return DerpStatus(is_private=False, error=f"Failed to parse DERP map JSON: {exc}")
    except Exception as exc:  # noqa: BLE001
        return DerpStatus(is_private=False, error=str(exc))


def check_logtail_suppression() -> LogtailStatus:
    """Check whether Tailscale logtail is suppressed locally.

    Looks for ``TS_NO_LOGS_NO_SUPPORT=true`` in the environment file
    appropriate for the detected OS.
    """
    os_type = detect_os_type()

    if os_type == OSType.WINDOWS:
        file_path = "C:/ProgramData/Tailscale/tailscaled-env.txt"
    else:
        # Linux and WSL2
        file_path = "/etc/default/tailscaled"

    try:
        path = Path(file_path)
        if not path.exists():
            return LogtailStatus(
                suppressed=False,
                file_path=file_path,
                file_exists=False,
            )

        content = path.read_text()
        suppressed = "TS_NO_LOGS_NO_SUPPORT=true" in content

        return LogtailStatus(
            suppressed=suppressed,
            file_path=file_path,
            file_exists=True,
        )

    except Exception as exc:  # noqa: BLE001
        return LogtailStatus(
            suppressed=False,
            file_path=file_path,
            file_exists=False,
            error=str(exc),
        )


def check_dns_acceptance() -> DnsStatus:
    """Check whether Tailscale DNS acceptance (MagicDNS) is enabled.

    Runs ``tailscale debug prefs`` and inspects the ``CorpDNS`` field.
    ``CorpDNS: true`` means accept-dns is enabled (MagicDNS active).
    """
    try:
        result = run(["tailscale", "debug", "prefs"], timeout=10)
        if not result.success:
            return DnsStatus(
                accept_dns=None,
                error=f"tailscale debug prefs failed: {result.stderr.strip()}",
            )

        prefs = json.loads(result.stdout)
        corp_dns = prefs.get("CorpDNS")

        return DnsStatus(
            accept_dns=bool(corp_dns) if corp_dns is not None else None,
            raw_prefs=prefs,
        )

    except json.JSONDecodeError as exc:
        return DnsStatus(accept_dns=None, error=f"Failed to parse prefs JSON: {exc}")
    except Exception as exc:  # noqa: BLE001
        return DnsStatus(accept_dns=None, error=str(exc))


def check_headscale_config(
    config_path: str = "/etc/headscale/config.yaml",
) -> HeadscaleConfigStatus:
    """Check Headscale configuration for hardening.

    Reads the YAML config and verifies:
    - Private DERP server is enabled
    - No public DERP map URLs are configured
    - Logtail is disabled
    - DNS override is disabled
    - Listen address is loopback-only
    """
    _defaults = dict(
        config_exists=False,
        derp_server_enabled=False,
        public_derp_urls_empty=False,
        logtail_disabled=False,
        dns_override_disabled=False,
        listen_loopback_only=False,
        is_hardened=False,
    )

    try:
        path = Path(config_path)
        if not path.exists():
            return HeadscaleConfigStatus(
                **_defaults,
                error=f"Config file not found: {config_path}",
            )

        content = path.read_text()
        config = yaml.safe_load(content) or {}

        derp = config.get("derp", {}) or {}
        derp_server = derp.get("server", {}) or {}
        derp_urls = derp.get("urls", None)

        logtail = config.get("logtail", {}) or {}
        dns = config.get("dns", {}) or {}
        listen_addr = config.get("listen_addr", "")

        derp_server_enabled = bool(derp_server.get("enabled", False))
        public_derp_urls_empty = derp_urls == [] or derp_urls is None
        logtail_disabled = not bool(logtail.get("enabled", True))
        dns_override_disabled = not bool(dns.get("override_local_dns", True))
        listen_loopback_only = str(listen_addr).startswith("127.0.0.1")

        is_hardened = all([
            derp_server_enabled,
            public_derp_urls_empty,
            logtail_disabled,
            dns_override_disabled,
            listen_loopback_only,
        ])

        return HeadscaleConfigStatus(
            config_exists=True,
            derp_server_enabled=derp_server_enabled,
            public_derp_urls_empty=public_derp_urls_empty,
            logtail_disabled=logtail_disabled,
            dns_override_disabled=dns_override_disabled,
            listen_loopback_only=listen_loopback_only,
            is_hardened=is_hardened,
        )

    except yaml.YAMLError as exc:
        return HeadscaleConfigStatus(
            **_defaults,
            error=f"Failed to parse YAML: {exc}",
        )
    except PermissionError:
        return HeadscaleConfigStatus(
            **_defaults,
            error=f"Permission denied reading {config_path}",
        )
    except Exception as exc:  # noqa: BLE001
        return HeadscaleConfigStatus(
            **_defaults,
            error=str(exc),
        )


def check_remote_logtail(host: str, port: int = 22) -> LogtailStatus:
    """Check logtail suppression on a remote host via SSH.

    Detects remote OS via ``uname -s`` and reads the appropriate
    environment file to check for ``TS_NO_LOGS_NO_SUPPORT=true``.
    """
    try:
        # Detect remote OS
        uname_result = subprocess.run(
            ["ssh", "-p", str(port), "-o", "ConnectTimeout=5", host, "uname -s"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if uname_result.returncode != 0:
            return LogtailStatus(
                suppressed=False,
                file_path="",
                file_exists=False,
                error=f"SSH to {host}:{port} failed: {uname_result.stderr.strip()}",
            )

        remote_os = uname_result.stdout.strip().lower()

        if "mingw" in remote_os or "cygwin" in remote_os or "msys" in remote_os:
            file_path = "C:/ProgramData/Tailscale/tailscaled-env.txt"
            cat_cmd = f"type {file_path}"
        else:
            file_path = "/etc/default/tailscaled"
            cat_cmd = f"cat {file_path}"

        # Read the file
        cat_result = subprocess.run(
            ["ssh", "-p", str(port), "-o", "ConnectTimeout=5", host, cat_cmd],
            capture_output=True,
            text=True,
            timeout=15,
        )

        if cat_result.returncode != 0:
            return LogtailStatus(
                suppressed=False,
                file_path=file_path,
                file_exists=False,
                error=None,
            )

        suppressed = "TS_NO_LOGS_NO_SUPPORT=true" in cat_result.stdout

        return LogtailStatus(
            suppressed=suppressed,
            file_path=file_path,
            file_exists=True,
        )

    except subprocess.TimeoutExpired:
        return LogtailStatus(
            suppressed=False,
            file_path="",
            file_exists=False,
            error=f"SSH to {host}:{port} timed out",
        )
    except Exception as exc:  # noqa: BLE001
        return LogtailStatus(
            suppressed=False,
            file_path="",
            file_exists=False,
            error=str(exc),
        )
