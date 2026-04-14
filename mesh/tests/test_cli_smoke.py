"""Smoke tests verifying CLI commands register and show help."""

from typer.testing import CliRunner

from mesh.cli import app

runner = CliRunner()


class TestCLIHelp:
    """Verify all commands are registered and respond to --help."""

    def test_mesh_help(self):
        result = runner.invoke(app, ["--help"])
        assert result.exit_code == 0
        assert "harden" in result.output

    def test_harden_help(self):
        result = runner.invoke(app, ["harden", "--help"])
        assert result.exit_code == 0
        assert "server" in result.output
        assert "client" in result.output
        assert "remote" in result.output
        assert "status" in result.output
        assert "show-templates" in result.output

    def test_harden_status_help(self):
        result = runner.invoke(app, ["harden", "status", "--help"])
        assert result.exit_code == 0
        assert "--verbose" in result.output

    def test_harden_client_help(self):
        result = runner.invoke(app, ["harden", "client", "--help"])
        assert result.exit_code == 0
        assert "--dry-run" in result.output

    def test_harden_server_help(self):
        result = runner.invoke(app, ["harden", "server", "--help"])
        assert result.exit_code == 0
        assert "--dry-run" in result.output

    def test_harden_show_templates_help(self):
        result = runner.invoke(app, ["harden", "show-templates", "--help"])
        assert result.exit_code == 0

    def test_harden_remote_help(self):
        result = runner.invoke(app, ["harden", "remote", "--help"])
        assert result.exit_code == 0

    def test_status_help(self):
        """Regression: mesh status still works."""
        result = runner.invoke(app, ["status", "--help"])
        assert result.exit_code == 0
        assert "--verbose" in result.output

    def test_harden_show_templates_runs(self):
        """show-templates actually lists templates, not just help."""
        result = runner.invoke(app, ["harden", "show-templates"])
        assert result.exit_code == 0
        assert "headscale-config-template.yaml" in result.output
