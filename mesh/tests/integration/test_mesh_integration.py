"""Integration tests for mesh CLI against a real heterogeneous mesh.

Tests a complete mesh: Headscale control plane + Linux Tailscale clients (Docker)
+ optionally a Windows Tailscale client (QEMU overlay VM). One mesh, one test suite.

Run via: ./tests/integration/run-tests.sh
"""

import json
from pathlib import Path

import pytest
import yaml

from tests._pii import FORBIDDEN


class TestHeadscaleHealth:
    """Verify Headscale control plane is operational."""

    def test_health(self, headscale_exec):
        result = headscale_exec(["headscale", "health"])
        assert result.returncode == 0

    def test_user_exists(self, headscale_exec):
        result = headscale_exec(["headscale", "users", "list", "-o", "json"])
        assert result.returncode == 0
        users = json.loads(result.stdout)
        names = [u["name"] for u in users]
        assert "testuser" in names

    def test_nodes_registered(self, headscale_exec):
        result = headscale_exec(["headscale", "nodes", "list", "-o", "json"])
        assert result.returncode == 0
        nodes = json.loads(result.stdout)
        hostnames = [n.get("givenName", n.get("name", "")) for n in nodes]
        assert "client-a" in hostnames
        assert "client-b" in hostnames

    def test_windows_nodes_registered(self, headscale_exec):
        result = headscale_exec(["headscale", "nodes", "list", "-o", "json"])
        assert result.returncode == 0
        nodes = json.loads(result.stdout)
        hostnames = [n.get("givenName", n.get("name", "")).lower() for n in nodes]
        for name in ("meshtest-win-a", "meshtest-win-b"):
            assert name in hostnames, f"{name} not in Headscale. Nodes: {hostnames}"


class TestClientMesh:
    """Verify Tailscale clients are connected and can see each other."""

    def test_client_a_connected(self, client_a_status):
        assert client_a_status["BackendState"] == "Running"

    def test_client_b_connected(self, client_b_status):
        assert client_b_status["BackendState"] == "Running"

    def test_client_a_sees_peer(self, client_a_status):
        peers = client_a_status.get("Peer", {})
        assert len(peers) >= 1
        peer_hosts = [p.get("HostName", "") for p in peers.values()]
        assert "client-b" in peer_hosts

    def test_client_b_sees_peer(self, client_b_status):
        peers = client_b_status.get("Peer", {})
        assert len(peers) >= 1
        peer_hosts = [p.get("HostName", "") for p in peers.values()]
        assert "client-a" in peer_hosts

    def test_peer_ping(self, client_a_exec):
        result = client_a_exec(
            ["tailscale", "ping", "-c", "1", "client-b"],
            timeout=30,
        )
        assert result.returncode == 0, f"Ping failed: {result.stderr}"


class TestDERPMapValidation:
    """Verify DERP map contains only private regions."""

    def test_no_public_derp_regions(self, client_a_status):
        derp_map = client_a_status.get("DERPMap", {})
        if not derp_map:
            pytest.skip("DERPMap not in tailscale status")
        regions = derp_map.get("Regions", {})
        for region_id_str, region in regions.items():
            region_id = int(region_id_str)
            assert region_id >= 900, (
                f"Public DERP region {region_id} ({region.get('RegionName', '')}) "
                "found — only private regions (ID >= 900) should be present"
            )

    def test_private_derp_present(self, client_a_status):
        derp_map = client_a_status.get("DERPMap", {})
        if not derp_map:
            pytest.skip("DERPMap not in tailscale status")
        regions = derp_map.get("Regions", {})
        private = [rid for rid in regions if int(rid) >= 900]
        assert len(private) >= 1, "No private DERP region found"


class TestLogtailSuppression:
    """Verify logtail is disabled in Headscale config."""

    def test_headscale_logtail_disabled(self):
        config_path = Path(__file__).parent / "headscale" / "config.yaml"
        config = yaml.safe_load(config_path.read_text())
        assert config["logtail"]["enabled"] is False


class TestDNSPolicy:
    """Verify DNS configuration."""

    def test_dns_uses_documentation_nameservers(self):
        config_path = Path(__file__).parent / "headscale" / "config.yaml"
        config = yaml.safe_load(config_path.read_text())
        nameservers = config["dns"]["nameservers"]["global"]
        for ns in nameservers:
            assert ns.startswith("203.0.113."), (
                f"Nameserver {ns} is not in TEST-NET-3 (203.0.113.0/24)"
            )

    def test_base_domain_is_generic(self):
        config_path = Path(__file__).parent / "headscale" / "config.yaml"
        config = yaml.safe_load(config_path.read_text())
        assert config["dns"]["base_domain"] == "example.com"

    def test_override_local_dns_disabled(self):
        config_path = Path(__file__).parent / "headscale" / "config.yaml"
        config = yaml.safe_load(config_path.read_text())
        assert config["dns"]["override_local_dns"] is False

    def test_public_derp_urls_empty(self):
        config_path = Path(__file__).parent / "headscale" / "config.yaml"
        config = yaml.safe_load(config_path.read_text())
        assert config["derp"]["urls"] == []


class TestTemplatePIIScrub:
    """Verify integration test config YAMLs contain no environment-specific PII.

    Uses the canonical `tests/_pii.FORBIDDEN` list. Substring match is fine
    here because the YAMLs don't contain placeholder IPs that overlap with
    `100.64.0.1..7` (the user's real addresses).
    """

    def test_headscale_config_no_pii(self):
        config_path = Path(__file__).parent / "headscale" / "config.yaml"
        content = config_path.read_text().lower()
        for pattern in FORBIDDEN:
            assert pattern.lower() not in content, (
                f"PII pattern '{pattern}' found in headscale config"
            )

    def test_derp_map_no_pii(self):
        derp_path = Path(__file__).parent / "headscale" / "derp.yaml"
        content = derp_path.read_text().lower()
        for pattern in FORBIDDEN:
            assert pattern.lower() not in content, (
                f"PII pattern '{pattern}' found in DERP map"
            )

    def test_acl_no_pii(self):
        acl_path = Path(__file__).parent / "headscale" / "acl.yaml"
        content = acl_path.read_text().lower()
        for pattern in FORBIDDEN:
            assert pattern.lower() not in content, (
                f"PII pattern '{pattern}' found in ACL policy"
            )


# --- Cross-platform mesh tests (Windows + Linux) ---


class TestCrossPlatformMesh:
    """Verify Windows and Linux nodes can see and reach each other."""

    def test_linux_sees_both_windows_peers(self, client_a_exec):
        result = client_a_exec(["tailscale", "status", "--json"])
        assert result.returncode == 0
        status = json.loads(result.stdout)
        peer_hosts = [p.get("HostName", "").lower() for p in status.get("Peer", {}).values()]
        for name in ("meshtest-win-a", "meshtest-win-b"):
            assert name in peer_hosts, f"{name} not visible from Linux. Peers: {peer_hosts}"

    def test_linux_pings_each_windows(self, client_a_exec, winvm):
        result = client_a_exec(
            ["tailscale", "ping", "-c", "1", winvm["name"]],
            timeout=30,
        )
        assert result.returncode == 0, f"Linux→{winvm['name']} ping failed: {result.stderr}"

    def test_windows_sees_linux_peers(self, winvm_exec):
        result = winvm_exec(
            '"C:\\Program Files\\Tailscale\\tailscale.exe" status --json'
        )
        assert result.returncode == 0, f"tailscale status failed: {result.stderr}"
        status = json.loads(result.stdout)
        peer_hosts = [p.get("HostName", "").lower() for p in status.get("Peer", {}).values()]
        assert "client-a" in peer_hosts, f"Linux not visible from Windows. Peers: {peer_hosts}"

    def test_windows_tailscale_running(self, winvm_exec):
        result = winvm_exec(
            '"C:\\Program Files\\Tailscale\\tailscale.exe" status --json'
        )
        assert result.returncode == 0
        status = json.loads(result.stdout)
        assert status.get("BackendState") == "Running"

    def test_windows_has_tailscale_ip(self, winvm_exec):
        result = winvm_exec(
            '"C:\\Program Files\\Tailscale\\tailscale.exe" ip -4'
        )
        assert result.returncode == 0
        ip = result.stdout.strip()
        assert ip.startswith("100.64."), f"Unexpected Tailscale IP: {ip}"
