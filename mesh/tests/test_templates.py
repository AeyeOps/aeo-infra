"""Tests for hardening template files."""

import csv
import io
import json

import pytest
import yaml

from mesh.core.templates import get_template, list_templates


class TestTemplateLoader:
    """Tests for the template loading mechanism."""

    def test_list_templates_returns_all(self):
        """All expected templates are listed."""
        templates = list_templates()
        expected = [
            "Caddyfile.headscale",
            "deployment-checklist.md",
            "firewall-port-matrix.csv",
            "headscale-config-template.yaml",
            "join-linux-node.sh",
            "join-windows-node.ps1",
            "policy.hujson",
            "tailscaled.default.private",
            "windows-tailscaled-env.txt",
        ]
        assert templates == expected

    def test_get_template_returns_content(self):
        """Each template loads without error."""
        for name in list_templates():
            content = get_template(name)
            assert len(content) > 0, f"Template {name} is empty"

    def test_get_template_unknown_raises(self):
        """Unknown template name raises an error."""
        with pytest.raises(FileNotFoundError):
            get_template("nonexistent-template.txt")


class TestHeadscaleConfigTemplate:
    """Validate the Headscale config template structure."""

    @pytest.fixture
    def config(self):
        return yaml.safe_load(get_template("headscale-config-template.yaml"))

    def test_derp_server_enabled(self, config):
        assert config["derp"]["server"]["enabled"] is True

    def test_derp_urls_empty(self, config):
        assert config["derp"]["urls"] == []

    def test_derp_paths_empty(self, config):
        assert config["derp"]["paths"] == []

    def test_logtail_disabled(self, config):
        assert config["logtail"]["enabled"] is False

    def test_magic_dns_enabled(self, config):
        assert config["dns"]["magic_dns"] is True

    def test_override_local_dns_disabled(self, config):
        assert config["dns"]["override_local_dns"] is False

    def test_global_nameservers_empty(self, config):
        assert config["dns"]["nameservers"]["global"] == []

    def test_listen_loopback(self, config):
        assert config["listen_addr"].startswith("127.0.0.1")

    def test_metrics_loopback(self, config):
        assert config["metrics_listen_addr"].startswith("127.0.0.1")

    def test_grpc_loopback(self, config):
        assert config["grpc_listen_addr"].startswith("127.0.0.1")

    def test_verify_clients_enabled(self, config):
        assert config["derp"]["server"]["verify_clients"] is True


class TestPolicyTemplate:
    """Validate the ACL policy template."""

    @pytest.fixture
    def policy(self):
        # HuJSON allows comments, but our template should be valid JSON
        return json.loads(get_template("policy.hujson"))

    def test_has_groups(self, policy):
        assert "groups" in policy

    def test_has_acls(self, policy):
        assert "acls" in policy

    def test_has_ssh(self, policy):
        assert "ssh" in policy

    def test_has_tag_owners(self, policy):
        assert "tagOwners" in policy


class TestFirewallMatrix:
    """Validate the firewall port matrix CSV."""

    @pytest.fixture
    def rows(self):
        content = get_template("firewall-port-matrix.csv")
        reader = csv.DictReader(io.StringIO(content))
        return list(reader)

    def test_has_expected_columns(self, rows):
        expected_cols = {"Component", "Direction", "Protocol", "Port", "Purpose", "Required"}
        assert expected_cols.issubset(set(rows[0].keys()))

    def test_has_headscale_port(self, rows):
        ports = [r["Port"] for r in rows]
        assert "8080" in ports

    def test_has_wireguard_port(self, rows):
        ports = [r["Port"] for r in rows]
        assert "41641" in ports


class TestJoinScripts:
    """Validate join script templates."""

    def test_linux_has_shebang(self):
        content = get_template("join-linux-node.sh")
        assert content.startswith("#!/")

    def test_linux_has_accept_dns_true(self):
        content = get_template("join-linux-node.sh")
        assert "--accept-dns=true" in content

    def test_windows_has_accept_dns_true(self):
        content = get_template("join-windows-node.ps1")
        assert "--accept-dns=true" in content


class TestLogtailTemplates:
    """Validate logtail suppression templates."""

    def test_linux_has_flag(self):
        content = get_template("tailscaled.default.private")
        assert "TS_NO_LOGS_NO_SUPPORT=true" in content

    def test_windows_has_flag(self):
        content = get_template("windows-tailscaled-env.txt")
        assert "TS_NO_LOGS_NO_SUPPORT=true" in content


class TestPIIScrub:
    """Verify NO template contains environment-specific PII."""

    FORBIDDEN = [
        "aeyeops",
        "sfspark",
        "aurora",
        "srv1540558",
        "xps13",
        "100.64.0.1",
        "100.64.0.2",
        "100.64.0.3",
        "100.64.0.5",
        "100.64.0.6",
        "100.64.0.7",
    ]

    def test_no_pii_in_any_template(self):
        """Every template file must be free of environment-specific values."""
        for name in list_templates():
            content = get_template(name).lower()
            for pattern in self.FORBIDDEN:
                assert pattern.lower() not in content, (
                    f"PII pattern '{pattern}' found in template '{name}'"
                )
