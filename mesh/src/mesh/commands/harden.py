"""Hardening commands for mesh network privacy and security."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

import typer

from mesh.core.environment import OSType, detect_os_type, detect_role, is_server
from mesh.core.privacy import (
    check_derp_map,
    check_dns_acceptance,
    check_headscale_config,
    check_logtail_suppression,
)
from mesh.core.templates import get_template, list_templates
from mesh.utils.output import error, info, ok, section, warn
from mesh.utils.process import run_sudo

app = typer.Typer(
    name="harden",
    help="Privacy hardening for mesh nodes and server",
    no_args_is_help=True,
)

# SSH options for non-interactive connections (same pattern as remote.py)
SSH_OPTS = [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "StrictHostKeyChecking=accept-new",
]

HEADSCALE_CONFIG_PATH = "/etc/headscale/config.yaml"
HEADSCALE_POLICY_PATH = "/etc/headscale/policy.hujson"

# Template descriptions for show-templates
TEMPLATE_DESCRIPTIONS: dict[str, str] = {
    "headscale-config-template.yaml": (
        "Hardened Headscale server config (loopback-only, private DERP, no logtail)"
    ),
    "policy.hujson": "ACL policy with group-based access control and SSH rules",
    "tailscaled.default.private": "Linux/WSL logtail suppression for /etc/default/tailscaled",
    "windows-tailscaled-env.txt": "Windows logtail suppression for tailscaled-env.txt",
    "Caddyfile.headscale": "Caddy reverse proxy config for Headscale HTTPS termination",
    "firewall-port-matrix.csv": "Port matrix reference for firewall configuration",
    "deployment-checklist.md": "Step-by-step deployment checklist for hardened mesh setup",
    "join-linux-node.sh": "Shell script to join a Linux node to the mesh",
    "join-windows-node.ps1": "PowerShell script to join a Windows node to the mesh",
}


def _require_server() -> None:
    """Ensure we're running on the coordination server."""
    if not is_server():
        role = detect_role()
        error(
            f"Server commands must be run on the coordination server (current role: {role.value})"
        )
        info("Configure your server hostname with MESH_SERVER_HOSTNAMES environment variable")
        raise typer.Exit(1)


def _ssh_run(host: str, port: int, cmd: str, timeout: int = 120) -> tuple[bool, str]:
    """Run a command on remote host via SSH."""
    ssh_cmd = ["ssh"] + SSH_OPTS + ["-p", str(port), host, cmd]
    try:
        result = subprocess.run(
            ssh_cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.returncode == 0, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except FileNotFoundError:
        return False, "SSH not found"


def _detect_remote_os(host: str, port: int) -> str | None:
    """Detect OS type of remote host. Returns 'linux', 'windows', or None."""
    success, output = _ssh_run(host, port, "uname -s", timeout=15)
    if success:
        out = output.strip().lower()
        if "linux" in out:
            return "linux"
        if "msys" in out or "mingw" in out or "cygwin" in out:
            return "windows"

    # Try Windows-specific command
    success, output = _ssh_run(host, port, "echo %OS%", timeout=15)
    if success and "windows" in output.lower():
        return "windows"

    return None


@app.command()
def server(
    dry_run: bool = typer.Option(
        False, "--dry-run", help="Show what would be written without deploying",
    ),
    config_only: bool = typer.Option(
        False, "--config-only", help="Deploy config without restarting service",
    ),
) -> None:
    """Deploy hardened Headscale configuration (server only)."""
    _require_server()

    section("Hardened Headscale Deployment")

    # Load template
    template = get_template("headscale-config-template.yaml")

    # Prompt user for values
    info("Configure Headscale server settings (placeholders use example.com)")
    server_url = typer.prompt(
        "Server URL",
        default="https://headscale.example.com",
    )
    base_domain = typer.prompt(
        "DNS base domain",
        default="mesh.example.net",
    )
    derp_ipv4 = typer.prompt(
        "DERP server public IPv4",
        default="203.0.113.10",
    )

    # Apply substitutions
    config_content = template.replace("https://headscale.example.com", server_url)
    config_content = config_content.replace("mesh.example.net", base_domain)
    config_content = config_content.replace("203.0.113.10", derp_ipv4)

    if dry_run:
        section("Dry Run: Config Preview")
        typer.echo(config_content)

        # Also show policy
        policy_content = get_template("policy.hujson")
        section("Dry Run: Policy Preview")
        typer.echo(policy_content)
        ok("Dry run complete, no files written")
        return

    # Backup existing config
    config_path = Path(HEADSCALE_CONFIG_PATH)
    if config_path.exists():
        backup_path = f"{HEADSCALE_CONFIG_PATH}.backup"
        info(f"Backing up existing config to {backup_path}")
        result = run_sudo(["cp", HEADSCALE_CONFIG_PATH, backup_path])
        if result.success:
            ok("Backup created")
        else:
            warn(f"Could not create backup: {result.stderr}")

    # Write new config via temp file + sudo cp
    info("Writing hardened config...")
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as tmp:
        tmp.write(config_content)
        tmp_path = tmp.name

    result = run_sudo(["cp", tmp_path, HEADSCALE_CONFIG_PATH])
    Path(tmp_path).unlink(missing_ok=True)
    if result.success:
        run_sudo(["chmod", "644", HEADSCALE_CONFIG_PATH])
        ok(f"Config written to {HEADSCALE_CONFIG_PATH}")
    else:
        error(f"Failed to write config: {result.stderr}")
        raise typer.Exit(1)

    # Deploy policy file
    info("Writing ACL policy...")
    policy_content = get_template("policy.hujson")
    with tempfile.NamedTemporaryFile(mode="w", suffix=".hujson", delete=False) as tmp:
        tmp.write(policy_content)
        tmp_path = tmp.name

    result = run_sudo(["cp", tmp_path, HEADSCALE_POLICY_PATH])
    Path(tmp_path).unlink(missing_ok=True)
    if result.success:
        run_sudo(["chmod", "644", HEADSCALE_POLICY_PATH])
        ok(f"Policy written to {HEADSCALE_POLICY_PATH}")
    else:
        warn(f"Could not write policy: {result.stderr}")

    # Restart service unless --config-only
    if config_only:
        info("Config-only mode: skipping service restart")
        ok("Deployment complete (restart manually with: sudo systemctl restart headscale)")
        return

    info("Restarting Headscale service...")
    result = run_sudo(["systemctl", "restart", "headscale"])
    if result.success:
        ok("Headscale service restarted")
    else:
        error(f"Failed to restart: {result.stderr}")
        info("Try manually: sudo systemctl restart headscale")
        raise typer.Exit(1)

    # Health check
    import time

    info("Waiting for health check...")
    time.sleep(2)

    from mesh.utils.process import run

    health = run(["curl", "-sf", "http://127.0.0.1:8080/health"], timeout=10)
    if health.success:
        ok("Health check passed")
    else:
        warn("Health check did not pass (service may still be starting)")
        info("Verify manually: curl http://127.0.0.1:8080/health")

    ok("Server hardening deployment complete")


@app.command()
def client(
    dry_run: bool = typer.Option(
        False, "--dry-run", help="Show what would be deployed without writing",
    ),
) -> None:
    """Deploy logtail suppression on the current node."""
    section("Client Logtail Suppression")

    os_type = detect_os_type()
    info(f"Detected OS: {os_type.value}")

    if os_type == OSType.WINDOWS:
        file_path = "C:\\ProgramData\\Tailscale\\tailscaled-env.txt"
        template_name = "windows-tailscaled-env.txt"
    elif os_type in (OSType.UBUNTU, OSType.WSL2):
        file_path = "/etc/default/tailscaled"
        template_name = "tailscaled.default.private"
    else:
        error(f"Unsupported OS type: {os_type.value}")
        raise typer.Exit(1)

    content = get_template(template_name)

    if dry_run:
        section(f"Dry Run: Would write to {file_path}")
        typer.echo(content)
        ok("Dry run complete, no files written")
        return

    # Deploy the file
    info(f"Deploying to {file_path}...")

    if os_type == OSType.WINDOWS:
        # Direct write on Windows
        try:
            Path(file_path).parent.mkdir(parents=True, exist_ok=True)
            Path(file_path).write_text(content)
            ok(f"Written to {file_path}")
        except PermissionError:
            error(f"Permission denied writing {file_path}")
            info("Run as administrator or use mesh harden remote for remote deployment")
            raise typer.Exit(1) from None
    else:
        # Linux/WSL: use sudo
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False) as tmp:
            tmp.write(content)
            tmp_path = tmp.name

        result = run_sudo(["cp", tmp_path, file_path])
        Path(tmp_path).unlink(missing_ok=True)
        if result.success:
            run_sudo(["chmod", "644", file_path])
            ok(f"Written to {file_path}")
        else:
            error(f"Failed to write: {result.stderr}")
            raise typer.Exit(1)

        # Restart tailscaled
        info("Restarting tailscaled service...")
        result = run_sudo(["systemctl", "restart", "tailscaled"])
        if result.success:
            ok("tailscaled restarted")
        else:
            warn(f"Could not restart tailscaled: {result.stderr}")
            info("Try manually: sudo systemctl restart tailscaled")

    # Verify by reading back
    info("Verifying deployment...")
    target = Path(file_path)
    if target.exists():
        actual = target.read_text()
        if "TS_NO_LOGS_NO_SUPPORT=true" in actual:
            ok("Verification passed: logtail suppression is active")
        else:
            warn("File exists but TS_NO_LOGS_NO_SUPPORT=true not found")
    else:
        # On Linux, may need sudo to read
        from mesh.utils.process import run

        verify = run(["sudo", "cat", file_path], timeout=5)
        if verify.success and "TS_NO_LOGS_NO_SUPPORT=true" in verify.stdout:
            ok("Verification passed: logtail suppression is active")
        else:
            warn("Could not verify file contents")


@app.command()
def remote(
    host: str = typer.Argument(..., help="Remote host (user@hostname or hostname)"),
    port: int = typer.Option(22, "--port", "-p", help="SSH port"),
) -> None:
    """Deploy logtail suppression on a remote node via SSH."""
    section(f"Remote Hardening: {host}:{port}")

    # Test connectivity
    info("Testing SSH connectivity...")
    success, output = _ssh_run(host, port, "echo connected")
    if not success:
        error(f"Cannot connect to {host}:{port}")
        error(f"SSH error: {output}")
        raise typer.Exit(1)
    ok("SSH connection successful")

    # Detect remote OS
    info("Detecting remote OS...")
    remote_os = _detect_remote_os(host, port)
    if not remote_os:
        error("Could not detect remote OS")
        raise typer.Exit(1)
    ok(f"Detected OS: {remote_os}")

    # Determine file path and content
    if remote_os == "windows":
        file_path = "C:\\ProgramData\\Tailscale\\tailscaled-env.txt"
        content = get_template("windows-tailscaled-env.txt")
    else:
        file_path = "/etc/default/tailscaled"
        content = get_template("tailscaled.default.private")

    info(f"Deploying logtail suppression to {file_path}...")

    if remote_os == "windows":
        # Write via PowerShell
        escaped_content = content.replace("'", "''")
        write_cmd = (
            f"powershell -Command \"Set-Content"
            f" -Path '{file_path}' -Value '{escaped_content}'\""
        )
        success, output = _ssh_run(host, port, write_cmd, timeout=15)
        if not success:
            error(f"Failed to write file: {output}")
            raise typer.Exit(1)
        ok(f"Written to {file_path}")

        # Restart Tailscale service
        info("Restarting Tailscale service...")
        success, output = _ssh_run(
            host, port,
            'powershell -Command "Restart-Service Tailscale"',
            timeout=30,
        )
        if success:
            ok("Tailscale service restarted")
        else:
            warn(f"Could not restart service: {output}")
    else:
        # Linux: write via sudo tee
        escaped_content = content.replace("'", "'\\''")
        write_cmd = f"echo '{escaped_content}' | sudo tee {file_path} > /dev/null"
        success, output = _ssh_run(host, port, write_cmd, timeout=15)
        if not success:
            error(f"Failed to write file: {output}")
            raise typer.Exit(1)
        ok(f"Written to {file_path}")

        # Restart tailscaled
        info("Restarting tailscaled service...")
        success, output = _ssh_run(host, port, "sudo systemctl restart tailscaled", timeout=30)
        if success:
            ok("tailscaled restarted")
        else:
            warn(f"Could not restart service: {output}")

    # Verify by reading back
    info("Verifying deployment...")
    if remote_os == "windows":
        verify_cmd = f"powershell -Command \"Get-Content '{file_path}'\""
    else:
        verify_cmd = f"cat {file_path}"

    success, output = _ssh_run(host, port, verify_cmd, timeout=10)
    if success and "TS_NO_LOGS_NO_SUPPORT=true" in output:
        ok("Verification passed: logtail suppression is active")
    else:
        warn("Could not verify file contents")

    ok(f"Remote hardening complete for {host}")


@app.command()
def status(
    verbose: bool = typer.Option(False, "--verbose", "-v", help="Show detailed check output"),
    json_output: bool = typer.Option(False, "--json", help="Output results as JSON"),
) -> None:
    """Validate hardening state of the current node."""
    if not json_output:
        section("Hardening Status")

    results: dict[str, dict] = {}
    passing = 0
    total = 0

    # Check 1: DERP map privacy
    total += 1
    derp = check_derp_map()
    results["derp"] = {"passing": derp.is_private, "summary": derp.summary()}
    if not json_output:
        section("DERP Relay Privacy")
        if derp.error:
            warn(derp.summary())
        elif derp.is_private:
            ok(derp.summary())
            passing += 1
        else:
            warn(derp.summary())
        if verbose and derp.regions:
            for region in derp.regions:
                label = "private" if region["id"] >= 100 else "PUBLIC"
                info(f"  Region {region['id']}: {region['name']} ({region['hostname']}) [{label}]")
    else:
        if derp.is_private:
            passing += 1

    # Check 2: Logtail suppression
    total += 1
    logtail = check_logtail_suppression()
    results["logtail"] = {"passing": logtail.suppressed, "summary": logtail.summary()}
    if not json_output:
        section("Logtail Suppression")
        if logtail.error:
            warn(logtail.summary())
        elif logtail.suppressed:
            ok(logtail.summary())
            passing += 1
        else:
            warn(logtail.summary())
            info("Fix with: mesh harden client")
        if verbose:
            info(f"  File: {logtail.file_path}")
            info(f"  Exists: {logtail.file_exists}")
    else:
        if logtail.suppressed:
            passing += 1

    # Check 3: DNS acceptance
    total += 1
    dns = check_dns_acceptance()
    # accept_dns=False is the hardened state (we don't want Tailscale overriding DNS)
    dns_passing = dns.accept_dns is False
    results["dns"] = {"passing": dns_passing, "summary": dns.summary()}
    if not json_output:
        section("DNS Acceptance")
        if dns.error:
            warn(dns.summary())
        elif dns_passing:
            ok("DNS: accept-dns disabled (hardened)")
            passing += 1
        else:
            warn(dns.summary())
            info("Fix with: tailscale set --accept-dns=false")
        if verbose and dns.raw_prefs:
            info(f"  CorpDNS: {dns.raw_prefs.get('CorpDNS')}")
    else:
        if dns_passing:
            passing += 1

    # Check 4: Headscale config (server only)
    total += 1
    hs_config = check_headscale_config()
    results["headscale_config"] = {"passing": hs_config.is_hardened, "summary": hs_config.summary()}
    if not json_output:
        section("Headscale Configuration")
        if hs_config.error:
            err_msg = hs_config.error or ""
            if "not found" in err_msg or "Permission denied" in err_msg:
                info(hs_config.summary() + " (expected on client nodes)")
            else:
                warn(hs_config.summary())
        elif hs_config.is_hardened:
            ok(hs_config.summary())
            passing += 1
        else:
            warn(hs_config.summary())
            info("Fix with: mesh harden server")
        if verbose and hs_config.config_exists:
            info(f"  DERP server enabled: {hs_config.derp_server_enabled}")
            info(f"  Public DERP URLs empty: {hs_config.public_derp_urls_empty}")
            info(f"  Logtail disabled: {hs_config.logtail_disabled}")
            info(f"  DNS override disabled: {hs_config.dns_override_disabled}")
            info(f"  Listen loopback only: {hs_config.listen_loopback_only}")
    else:
        if hs_config.is_hardened:
            passing += 1

    # Output
    if json_output:
        output = {
            "passing": passing,
            "total": total,
            "checks": results,
        }
        typer.echo(json.dumps(output, indent=2))
    else:
        section("Summary")
        if passing == total:
            ok(f"All {total} hardening checks passing")
        else:
            warn(f"{passing} of {total} hardening checks passing")
            if not verbose:
                info("Run with --verbose for detailed output")


@app.command(name="show-templates")
def show_templates(
    show: str | None = typer.Option(None, "--show", help="Print contents of a specific template"),
) -> None:
    """List available hardening templates."""
    if show:
        try:
            content = get_template(show)
            section(f"Template: {show}")
            typer.echo(content)
        except FileNotFoundError:
            error(f"Template not found: {show}")
            info("Run 'mesh harden show-templates' to see available templates")
            raise typer.Exit(1) from None
        return

    section("Available Templates")
    templates = list_templates()
    for name in templates:
        description = TEMPLATE_DESCRIPTIONS.get(name, "No description available")
        info(f"{name}")
        typer.echo(f"    {description}")
