"""Unit tests for host registry functionality."""

import tempfile
from pathlib import Path
from unittest.mock import patch

import pytest

from mesh.core.config import (
    Host,
    InvalidHostnameError,
    add_host,
    get_host,
    load_hosts,
    remove_host,
    save_hosts,
    validate_hostname,
)


@pytest.fixture
def temp_config_dir(tmp_path: Path):
    """Create a temporary config directory for testing."""
    with patch("mesh.core.config.get_mesh_config_dir", return_value=tmp_path):
        yield tmp_path


class TestValidateHostname:
    """Tests for hostname validation."""

    def test_valid_hostnames(self):
        assert validate_hostname("ubu1") is True
        assert validate_hostname("office-one") is True
        assert validate_hostname("server_01") is True
        assert validate_hostname("a") is True
        assert validate_hostname("A1-b2_c3") is True

    def test_invalid_hostnames(self):
        assert validate_hostname("") is False
        assert validate_hostname("host name") is False  # spaces
        assert validate_hostname("-host") is False  # starts with hyphen
        assert validate_hostname("_host") is False  # starts with underscore
        assert validate_hostname("host@name") is False  # special char
        assert validate_hostname("host.name") is False  # dot
        assert validate_hostname("a" * 64) is False  # too long


class TestHostRegistry:
    """Tests for host registry CRUD operations."""

    def test_add_host_creates_entry(self, temp_config_dir):
        host = add_host("ubu1", "192.168.50.10", 22, "steve")

        assert host.name == "ubu1"
        assert host.ip == "192.168.50.10"
        assert host.port == 22
        assert host.user == "steve"

        # Verify persisted
        loaded = get_host("ubu1")
        assert loaded is not None
        assert loaded.ip == "192.168.50.10"

    def test_add_host_is_idempotent(self, temp_config_dir):
        add_host("ubu1", "192.168.50.10", 22, "steve")
        add_host("ubu1", "192.168.50.10", 22, "steve")  # Second call

        hosts = load_hosts()
        assert len(hosts) == 1  # Still only one entry

    def test_add_host_updates_existing(self, temp_config_dir):
        add_host("ubu1", "192.168.50.10", 22, "steve")
        add_host("ubu1", "192.168.50.20", 2222, "admin")  # Update

        host = get_host("ubu1")
        assert host is not None
        assert host.ip == "192.168.50.20"
        assert host.port == 2222
        assert host.user == "admin"

    def test_add_host_invalid_hostname_raises(self, temp_config_dir):
        with pytest.raises(InvalidHostnameError):
            add_host("invalid host", "192.168.50.10", 22, "steve")

        with pytest.raises(InvalidHostnameError):
            add_host("", "192.168.50.10", 22, "steve")

    def test_remove_host(self, temp_config_dir):
        add_host("ubu1", "192.168.50.10", 22, "steve")

        result = remove_host("ubu1")
        assert result is True
        assert get_host("ubu1") is None

    def test_remove_nonexistent_host(self, temp_config_dir):
        result = remove_host("nonexistent")
        assert result is False

    def test_get_host_not_found(self, temp_config_dir):
        assert get_host("nonexistent") is None

    def test_load_hosts_empty(self, temp_config_dir):
        hosts = load_hosts()
        assert hosts == {}

    def test_load_hosts_multiple(self, temp_config_dir):
        add_host("host1", "192.168.1.1", 22, "user1")
        add_host("host2", "192.168.1.2", 2222, "user2")

        hosts = load_hosts()
        assert len(hosts) == 2
        assert "host1" in hosts
        assert "host2" in hosts

    def test_load_hosts_handles_malformed_yaml(self, temp_config_dir):
        """Test that malformed YAML entries are skipped."""
        hosts_file = temp_config_dir / "hosts.yaml"
        hosts_file.write_text(
            """hosts:
  valid_host:
    ip: 192.168.1.1
    port: 22
    user: steve
  null_host: null
  invalid_host: "just a string"
"""
        )

        hosts = load_hosts()
        assert len(hosts) == 1
        assert "valid_host" in hosts
        assert "null_host" not in hosts
        assert "invalid_host" not in hosts


class TestSSHHost:
    """Tests for SSH config host management."""

    def test_add_ssh_host(self, tmp_path: Path):
        from mesh.utils.ssh import add_ssh_host, get_ssh_config_path, host_exists

        with patch("mesh.utils.ssh.get_ssh_config_path", return_value=tmp_path / "config"):
            # Add a host
            result = add_ssh_host("testhost", "192.168.1.1", 22, "testuser")
            assert result is True

            # Verify it exists
            assert host_exists("testhost") is True

            # Check content
            content = (tmp_path / "config").read_text()
            assert "Host testhost" in content
            assert "HostName 192.168.1.1" in content
            assert "Port 22" in content
            assert "User testuser" in content

    def test_remove_ssh_host(self, tmp_path: Path):
        from mesh.utils.ssh import add_ssh_host, get_ssh_config_path, host_exists, remove_ssh_host

        with patch("mesh.utils.ssh.get_ssh_config_path", return_value=tmp_path / "config"):
            add_ssh_host("testhost", "192.168.1.1", 22, "testuser")
            assert host_exists("testhost") is True

            result = remove_ssh_host("testhost")
            assert result is True
            assert host_exists("testhost") is False

    def test_host_exists_static_entry(self, tmp_path: Path):
        from mesh.utils.ssh import get_ssh_config_path, host_exists

        config_file = tmp_path / "config"
        config_file.write_text(
            """Host myserver
    HostName server.local
    User admin
"""
        )

        with patch("mesh.utils.ssh.get_ssh_config_path", return_value=config_file):
            assert host_exists("myserver") is True
            assert host_exists("nonexistent") is False
