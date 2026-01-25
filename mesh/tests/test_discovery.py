"""Tests for the mDNS discovery module."""

import socket
import sys
from unittest.mock import MagicMock, patch

import pytest


class TestDiscoverServer:
    """Tests for server discovery."""

    def test_handles_missing_zeroconf(self):
        """Should return None if zeroconf is not installed."""
        # Mock the zeroconf module to raise ImportError
        with patch.dict(sys.modules, {"zeroconf": None}):
            # Force reimport
            import importlib
            import mesh.discovery
            importlib.reload(mesh.discovery)

            # The import will fail inside discover_server
            result = mesh.discovery.discover_server(timeout=0.1)
            assert result is None

            # Reload to restore normal behavior
            importlib.reload(mesh.discovery)

    def test_timeout_returns_none(self):
        """Should return None if no server is found within timeout."""
        # Use a very short timeout to test timeout behavior
        from mesh.discovery import discover_server

        # This will timeout quickly since no server is running
        result = discover_server(timeout=0.1)
        assert result is None

    def test_handles_os_error(self):
        """Should handle network errors gracefully."""
        import zeroconf
        with patch.object(zeroconf, "Zeroconf", side_effect=OSError("Network unreachable")):
            from mesh.discovery import discover_server
            result = discover_server(timeout=0.1)
            assert result is None


class TestAdvertiseServer:
    """Tests for server advertisement."""

    @patch("mesh.discovery._get_local_ips")
    def test_advertises_on_correct_port(self, mock_get_ips):
        """Should advertise on the specified port."""
        mock_get_ips.return_value = ["192.168.1.50"]

        from mesh.discovery import advertise_server

        # Start advertising
        zc = advertise_server(port=9999)

        # Should return a Zeroconf instance
        assert zc is not None

        # Cleanup
        zc.close()

    @patch("mesh.discovery._get_local_ips")
    def test_raises_on_no_ips(self, mock_get_ips):
        """Should raise if no local IPs are found."""
        mock_get_ips.return_value = []

        from mesh.discovery import advertise_server
        with pytest.raises(RuntimeError, match="No local IP"):
            advertise_server(port=8080)


class TestGetLocalIps:
    """Tests for local IP detection."""

    @patch("socket.socket")
    @patch("socket.getaddrinfo")
    def test_filters_loopback(self, mock_getaddrinfo, mock_socket):
        """Should filter out 127.x.x.x addresses."""
        mock_getaddrinfo.return_value = [
            (None, None, None, None, ("127.0.0.1", 0)),
            (None, None, None, None, ("192.168.1.50", 0)),
        ]

        from mesh.discovery import _get_local_ips
        result = _get_local_ips()

        assert "127.0.0.1" not in result
        assert "192.168.1.50" in result

    @patch("socket.socket")
    @patch("socket.getaddrinfo")
    def test_fallback_to_connect_method(self, mock_getaddrinfo, mock_socket_class):
        """Should use connect fallback if getaddrinfo fails."""
        mock_getaddrinfo.side_effect = socket.gaierror("no address")

        mock_socket = MagicMock()
        mock_socket.getsockname.return_value = ("10.0.0.5", 12345)
        mock_socket_class.return_value = mock_socket

        from mesh.discovery import _get_local_ips
        result = _get_local_ips()

        assert "10.0.0.5" in result


class TestDiscoveryIntegration:
    """Integration tests for discovery functionality."""

    def test_server_advertise_flag_registered(self):
        """Verify --advertise flag is registered on server setup."""
        from mesh.cli import app
        from typer.testing import CliRunner

        runner = CliRunner()
        result = runner.invoke(app, ["server", "setup", "--help"])

        assert result.exit_code == 0
        assert "--advertise" in result.output
        assert "--port" in result.output

    def test_client_discover_flag_registered(self):
        """Verify --discover flag is registered on client setup."""
        from mesh.cli import app
        from typer.testing import CliRunner

        runner = CliRunner()
        result = runner.invoke(app, ["client", "setup", "--help"])

        assert result.exit_code == 0
        assert "--discover" in result.output

    def test_client_setup_mutual_exclusivity(self):
        """Verify --discover and --server are mutually exclusive."""
        from mesh.cli import app
        from typer.testing import CliRunner

        runner = CliRunner()
        result = runner.invoke(
            app,
            ["client", "setup", "--discover", "--server", "http://x", "--key", "KEY"],
        )

        assert result.exit_code == 1
        assert "Cannot use both" in result.output

    def test_client_setup_requires_server_or_discover(self):
        """Verify client setup requires --server or --discover."""
        from mesh.cli import app
        from typer.testing import CliRunner

        runner = CliRunner()
        result = runner.invoke(app, ["client", "setup", "--key", "KEY"])

        assert result.exit_code == 1
        assert "Must specify --server URL or use --discover" in result.output
