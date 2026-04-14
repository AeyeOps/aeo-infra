"""Fixtures for mesh integration tests.

Provides helpers for all three node types in the heterogeneous mesh:
- Headscale control plane (Docker)
- Linux Tailscale clients (Docker)
- Windows Tailscale client (QEMU overlay VM)
"""

import json
import os
import subprocess

import pytest

HEADSCALE_CONTAINER = "meshtest-headscale"
CLIENT_A_CONTAINER = "meshtest-client-a"
CLIENT_B_CONTAINER = "meshtest-client-b"


def docker_exec(
    container: str, cmd: list[str], *, timeout: int = 15
) -> subprocess.CompletedProcess:
    """Run a command inside a Docker container."""
    return subprocess.run(
        ["docker", "exec", container] + cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def ssh_exec(
    ip: str, cmd: str, *, user: str = "testuser", timeout: int = 30
) -> subprocess.CompletedProcess:
    """Run a command on a remote host via SSH."""
    return subprocess.run(
        [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            f"{user}@{ip}",
            cmd,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


# --- Headscale fixtures ---


@pytest.fixture(scope="session")
def authkey():
    """The preauth key created by run-tests.sh, passed via env."""
    key = os.environ.get("AUTHKEY")
    if not key:
        pytest.fail("AUTHKEY not set — run via run-tests.sh")
    return key


@pytest.fixture(scope="session")
def headscale_exec():
    """Helper to exec commands in the Headscale container."""
    def _exec(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
        return docker_exec(HEADSCALE_CONTAINER, cmd, **kwargs)
    return _exec


# --- Linux client fixtures ---


@pytest.fixture(scope="session")
def client_a_exec():
    """Helper to exec commands in client-a container."""
    def _exec(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
        return docker_exec(CLIENT_A_CONTAINER, cmd, **kwargs)
    return _exec


@pytest.fixture(scope="session")
def client_b_exec():
    """Helper to exec commands in client-b container."""
    def _exec(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
        return docker_exec(CLIENT_B_CONTAINER, cmd, **kwargs)
    return _exec


@pytest.fixture(scope="session")
def client_a_status(client_a_exec):
    """Tailscale status JSON from client-a."""
    result = client_a_exec(["tailscale", "status", "--json"])
    assert result.returncode == 0, f"tailscale status failed: {result.stderr}"
    return json.loads(result.stdout)


@pytest.fixture(scope="session")
def client_b_status(client_b_exec):
    """Tailscale status JSON from client-b."""
    result = client_b_exec(["tailscale", "status", "--json"])
    assert result.returncode == 0, f"tailscale status failed: {result.stderr}"
    return json.loads(result.stdout)


# --- Windows VM fixtures ---


@pytest.fixture(scope="session")
def winvm_ip():
    """Windows VM IP address."""
    return os.environ.get("WINVM_IP", "192.168.50.200")


@pytest.fixture(scope="session")
def winvm_user():
    """Windows VM SSH user."""
    return os.environ.get("WINVM_USER", "testuser")


@pytest.fixture(scope="session")
def winvm_exec(winvm_ip, winvm_user):
    """Helper to exec commands on the Windows VM via SSH."""
    def _exec(cmd: str, **kwargs) -> subprocess.CompletedProcess:
        return ssh_exec(winvm_ip, cmd, user=winvm_user, **kwargs)
    return _exec
