"""Integration tests for Windows VM in the mesh network.

These tests only run when --with-windows is passed to run-tests.sh.
They validate cross-platform mesh connectivity and Windows-specific
hardening paths.
"""

import json

import pytest


class TestWindowsMeshConnectivity:
    """Verify Windows VM is part of the mesh and can communicate with Linux peers."""

    def test_windows_registered_in_headscale(self, windows_ready, headscale_exec):
        """Windows node appears in Headscale node list."""
        if not windows_ready:
            pytest.skip("Windows VM not available")

        result = headscale_exec(["headscale", "nodes", "list", "-o", "json"])
        assert result.returncode == 0
        nodes = json.loads(result.stdout)
        hostnames = [n.get("givenName", n.get("name", "")).lower() for n in nodes]
        assert "windows-test" in hostnames, (
            f"Windows node not found in Headscale. Nodes: {hostnames}"
        )

    def test_linux_sees_windows_peer(self, windows_ready, client_a_exec):
        """Linux client-a can see the Windows node as a peer."""
        if not windows_ready:
            pytest.skip("Windows VM not available")

        result = client_a_exec(["tailscale", "status", "--json"])
        assert result.returncode == 0
        status = json.loads(result.stdout)
        peer_hosts = [
            p.get("HostName", "").lower()
            for p in status.get("Peer", {}).values()
        ]
        assert "windows-test" in peer_hosts, (
            f"Windows peer not visible from client-a. Peers: {peer_hosts}"
        )

    def test_linux_pings_windows(self, windows_ready, client_a_exec):
        """Linux client-a can tailscale ping the Windows node."""
        if not windows_ready:
            pytest.skip("Windows VM not available")

        result = client_a_exec(
            ["tailscale", "ping", "-c", "1", "windows-test"],
            timeout=30,
        )
        assert result.returncode == 0, (
            f"Ping to Windows failed: {result.stderr}"
        )

    def test_windows_sees_linux_peers(self, winvm_exec):
        """Windows node can see Linux peers via tailscale status."""
        result = winvm_exec(
            '& "C:\\Program Files\\Tailscale\\tailscale.exe" status --json'
        )
        assert result.returncode == 0, f"tailscale status failed: {result.stderr}"
        status = json.loads(result.stdout)
        peer_hosts = [
            p.get("HostName", "").lower()
            for p in status.get("Peer", {}).values()
        ]
        assert "client-a" in peer_hosts, (
            f"client-a not visible from Windows. Peers: {peer_hosts}"
        )


class TestWindowsTailscaleState:
    """Verify Tailscale is properly configured on the Windows VM."""

    def test_tailscale_running(self, winvm_exec):
        """Tailscale backend is in Running state on Windows."""
        result = winvm_exec(
            '& "C:\\Program Files\\Tailscale\\tailscale.exe" status --json'
        )
        assert result.returncode == 0
        status = json.loads(result.stdout)
        assert status.get("BackendState") == "Running"

    def test_tailscale_has_ip(self, winvm_exec):
        """Windows node has a Tailscale IP assigned."""
        result = winvm_exec(
            '& "C:\\Program Files\\Tailscale\\tailscale.exe" ip -4'
        )
        assert result.returncode == 0
        ip = result.stdout.strip()
        assert ip.startswith("100.64."), f"Unexpected Tailscale IP: {ip}"
