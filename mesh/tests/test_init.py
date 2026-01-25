"""Tests for the init wizard module."""

import os
import platform
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from mesh.commands.init import (
    detect_platform,
    get_hostname,
    read_existing_env,
    write_env_file,
)


class TestDetectPlatform:
    """Tests for platform detection."""

    @patch("mesh.commands.init.detect_os_type")
    @patch("platform.machine")
    def test_linux_x64(self, mock_machine, mock_os_type):
        from mesh.core.environment import OSType
        mock_os_type.return_value = OSType.UBUNTU
        mock_machine.return_value = "x86_64"

        result = detect_platform()
        assert result == "Linux (x64)"

    @patch("mesh.commands.init.detect_os_type")
    @patch("platform.machine")
    def test_linux_arm64(self, mock_machine, mock_os_type):
        from mesh.core.environment import OSType
        mock_os_type.return_value = OSType.UBUNTU
        mock_machine.return_value = "aarch64"

        result = detect_platform()
        assert result == "Linux (arm64)"

    @patch("mesh.commands.init.detect_os_type")
    @patch("platform.machine")
    def test_wsl2(self, mock_machine, mock_os_type):
        from mesh.core.environment import OSType
        mock_os_type.return_value = OSType.WSL2
        mock_machine.return_value = "x86_64"

        result = detect_platform()
        assert result == "WSL2 (x64)"

    @patch("mesh.commands.init.detect_os_type")
    @patch("platform.machine")
    def test_windows_arm64(self, mock_machine, mock_os_type):
        from mesh.core.environment import OSType
        mock_os_type.return_value = OSType.WINDOWS
        mock_machine.return_value = "arm64"

        result = detect_platform()
        assert result == "Windows (arm64)"


class TestGetHostname:
    """Tests for hostname retrieval."""

    @patch("socket.gethostname")
    def test_returns_hostname(self, mock_gethostname):
        mock_gethostname.return_value = "testhost"
        assert get_hostname() == "testhost"


class TestReadExistingEnv:
    """Tests for reading existing .env files."""

    @patch("mesh.commands.init.ENV_PATH")
    def test_nonexistent_file(self, mock_path):
        mock_path.exists.return_value = False
        result = read_existing_env()
        assert result == {}

    @patch("mesh.commands.init.ENV_PATH")
    def test_parses_env_file(self, mock_path):
        mock_path.exists.return_value = True
        mock_path.read_text.return_value = """
# Comment
KEY1=value1
KEY2=value2
EMPTY=
"""
        result = read_existing_env()
        assert result == {
            "KEY1": "value1",
            "KEY2": "value2",
            "EMPTY": "",
        }

    @patch("mesh.commands.init.ENV_PATH")
    def test_ignores_invalid_lines(self, mock_path):
        mock_path.exists.return_value = True
        mock_path.read_text.return_value = """
VALID=value
invalid line without equals
# comment
"""
        result = read_existing_env()
        assert result == {"VALID": "value"}


class TestWriteEnvFile:
    """Tests for writing .env files."""

    @patch("mesh.commands.init.read_existing_env")
    @patch("mesh.commands.init.ENV_PATH")
    def test_dry_run_does_not_write(self, mock_path, mock_read):
        mock_read.return_value = {}
        mock_path.exists.return_value = False

        write_env_file({"KEY": "value"}, dry_run=True)

        mock_path.write_text.assert_not_called()

    @patch("shutil.copy")
    @patch("mesh.commands.init.read_existing_env")
    @patch("mesh.commands.init.ENV_PATH")
    def test_creates_backup(self, mock_path, mock_read, mock_copy):
        mock_read.return_value = {}
        mock_path.exists.return_value = True
        mock_backup = MagicMock()
        mock_path.with_suffix.return_value = mock_backup

        write_env_file({"KEY": "value"}, dry_run=False)

        mock_copy.assert_called_once_with(mock_path, mock_backup)

    @patch("shutil.copy")
    @patch("mesh.commands.init.read_existing_env")
    @patch("mesh.commands.init.ENV_PATH")
    def test_merges_with_existing(self, mock_path, mock_read, mock_copy):
        mock_read.return_value = {"EXISTING": "old"}
        mock_path.exists.return_value = True
        mock_path.with_suffix.return_value = MagicMock()

        write_env_file({"NEW": "value"}, dry_run=False)

        # Verify write was called with merged content
        call_args = mock_path.write_text.call_args[0][0]
        assert "EXISTING=old" in call_args
        assert "NEW=value" in call_args


class TestInitIntegration:
    """Integration tests for the init command."""

    def test_init_command_registered(self):
        """Verify init command is registered in CLI."""
        from mesh.cli import app
        from typer.testing import CliRunner

        runner = CliRunner()
        result = runner.invoke(app, ["init", "--help"])

        assert result.exit_code == 0
        assert "Interactive setup wizard" in result.output
        assert "--dry-run" in result.output

    def test_init_dry_run_shows_preview(self):
        """Verify --dry-run shows what would be written."""
        from mesh.cli import app
        from typer.testing import CliRunner

        runner = CliRunner()
        # Provide inputs: role (client), server URL, client type (linux), shared folder (n)
        result = runner.invoke(
            app,
            ["init", "--dry-run"],
            input="client\nhttp://test:8080\nlinux\nn\n",
        )

        # Should show dry run output
        assert "Dry Run" in result.output
        assert result.exit_code == 0
