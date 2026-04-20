"""Tests for hardening template files."""

import csv
import io
import json
import re
from pathlib import Path

import pytest
import yaml

from mesh.core.templates import get_template, list_templates
from tests._pii import FORBIDDEN, compiled_patterns


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
    """Verify NO template contains environment-specific PII.

    Substring match against the canonical FORBIDDEN list in `tests/_pii.py`.
    Templates are small and tightly controlled, so substring is sufficient.
    """

    def test_no_pii_in_any_template(self):
        """Every template file must be free of environment-specific values."""
        for name in list_templates():
            content = get_template(name).lower()
            for pattern in FORBIDDEN:
                assert pattern.lower() not in content, (
                    f"PII pattern '{pattern}' found in template '{name}'"
                )


class TestRepoPIIScrub:
    """Verify repo-level docs and scripts do not re-introduce PII.

    Template-level TestPIIScrub was not enough — real usernames, hostnames,
    and Tailscale IPs had leaked into docs/, setup-mesh.ps1, and vms/ scripts
    despite the templates being clean. This test covers the surfaces that
    are visible to users of the public repo.

    Uses regex with word boundaries so `100.64.0.1` does NOT match the
    placeholder IPs `100.64.0.10+` that legitimately appear in example docs.
    """

    PATTERNS: list[re.Pattern[str]] = compiled_patterns()

    # Directories that are gitignored or discuss the PII list itself — not leaks.
    SKIP_DIRS = frozenset({"archive", ".claude", ".venv", "__pycache__"})

    def _repo_root(self) -> Path:
        # tests/ → mesh/ → repo root
        return Path(__file__).resolve().parent.parent.parent

    def _assert_clean(self, path, content: str, context: str) -> None:
        for pat in self.PATTERNS:
            m = pat.search(content)
            assert m is None, (
                f"PII pattern /{pat.pattern}/ found in {context}: {path} "
                f"(matched: {m.group()!r})"
            )

    def _skip(self, rel: Path) -> bool:
        return any(part in self.SKIP_DIRS for part in rel.parts) or rel.name == "CLAUDE.md"

    def test_no_pii_in_mesh_docs(self):
        mesh_root = Path(__file__).resolve().parent.parent
        for path in mesh_root.rglob("*.md"):
            rel = path.relative_to(mesh_root)
            if self._skip(rel):
                continue
            self._assert_clean(rel, path.read_text(errors="ignore"), "mesh doc")

    def test_no_pii_in_mesh_powershell(self):
        mesh_root = Path(__file__).resolve().parent.parent
        for path in mesh_root.rglob("*.ps1"):
            rel = path.relative_to(mesh_root)
            if self._skip(rel):
                continue
            self._assert_clean(path.name, path.read_text(errors="ignore"), "PowerShell")

    def test_no_pii_in_vms_scripts(self):
        vms_root = self._repo_root() / "vms"
        if not vms_root.exists():
            return
        for ext in ("*.sh", "*.md"):
            for path in vms_root.rglob(ext):
                self._assert_clean(
                    path.relative_to(self._repo_root()),
                    path.read_text(errors="ignore"),
                    "vms script/doc",
                )

    def test_no_pii_in_mesh_readme(self):
        readme = Path(__file__).resolve().parent.parent / "README.md"
        self._assert_clean("mesh/README.md", readme.read_text(), "README")
