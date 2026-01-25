"""Headscale server management."""

import httpx

from mesh.utils.process import command_exists, run, run_sudo

HEADSCALE_VERSION = "0.27.1"
HEADSCALE_URL = f"https://github.com/juanfont/headscale/releases/download/v{HEADSCALE_VERSION}"


def is_installed() -> bool:
    """Check if Headscale is installed."""
    return command_exists("headscale")


def is_running() -> bool:
    """Check if Headscale service is running."""
    result = run(["systemctl", "is-active", "headscale"])
    return result.success and result.stdout.strip() == "active"


def get_health(server_url: str) -> bool:
    """Check Headscale server health."""
    try:
        resp = httpx.get(f"{server_url}/health", timeout=5)
        return resp.status_code == 200
    except httpx.RequestError:
        return False


def create_user(name: str) -> bool:
    """Create a Headscale user/namespace."""
    result = run_sudo(["headscale", "users", "create", name])
    return result.success or "already exists" in result.stderr.lower()


def get_user_id(username: str) -> int | None:
    """Get user ID from username (headscale 0.27+ requires ID, not name)."""
    import json

    result = run_sudo(["headscale", "users", "list", "--output", "json"])
    if result.success:
        try:
            users = json.loads(result.stdout)
            for user in users:
                if user.get("name") == username or user.get("username") == username:
                    return user.get("id")
        except json.JSONDecodeError:
            pass
    return None


def create_preauth_key(user: str, reusable: bool = True, ephemeral: bool = False) -> str | None:
    """Create a pre-authentication key."""
    import json
    import re

    # Headscale 0.27+ requires user ID, not username
    user_id = get_user_id(user)
    if user_id is None:
        return None

    cmd = ["headscale", "preauthkeys", "create", "--user", str(user_id), "--output", "json"]
    if reusable:
        cmd.append("--reusable")
    if ephemeral:
        cmd.append("--ephemeral")

    result = run_sudo(cmd)
    if result.success:
        output = result.stdout.strip()

        # Try parsing full JSON first
        try:
            data = json.loads(output)
            if key := data.get("key"):
                return key
        except json.JSONDecodeError:
            pass

        # Headscale may pollute stdout with warnings (issue #1797)
        # Try to find JSON by locating outermost braces
        try:
            start = output.index("{")
            end = output.rindex("}") + 1
            data = json.loads(output[start:end])
            if key := data.get("key"):
                return key
        except (ValueError, json.JSONDecodeError):
            pass

        # Fallback: look for the key on a line by itself (48+ char hex string)
        for line in output.split("\n"):
            line = line.strip()
            if re.match(r"^[a-f0-9]{48,}$", line):
                return line
    return None


def list_nodes(user: str | None = None) -> list[dict]:
    """List registered nodes."""
    cmd = ["headscale", "nodes", "list", "--output", "json"]
    if user:
        # Headscale 0.27+ requires user ID, not username
        user_id = get_user_id(user)
        if user_id:
            cmd.extend(["--user", str(user_id)])

    result = run_sudo(cmd)
    if result.success:
        import json

        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return []
    return []


def get_server_url() -> str:
    """Get the Headscale server URL from config."""
    # TODO: Parse actual config file to get URL
    # For now, return default
    return "http://localhost:8080"


def install_headscale() -> bool:
    """Install Headscale binary."""
    import platform

    arch = platform.machine()
    if arch == "aarch64":
        arch = "arm64"
    elif arch == "x86_64":
        arch = "amd64"

    url = f"{HEADSCALE_URL}/headscale_{HEADSCALE_VERSION}_linux_{arch}.deb"

    # Download and install
    result = run(["curl", "-fsSL", "-o", "/tmp/headscale.deb", url])
    if not result.success:
        return False

    result = run_sudo(["dpkg", "-i", "/tmp/headscale.deb"])
    return result.success
