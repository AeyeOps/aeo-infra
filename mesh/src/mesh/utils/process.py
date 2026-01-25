"""Subprocess execution helpers."""

import shutil
import subprocess
from dataclasses import dataclass


@dataclass
class CommandResult:
    """Result of a command execution."""

    returncode: int
    stdout: str
    stderr: str

    @property
    def success(self) -> bool:
        """Check if command succeeded."""
        return self.returncode == 0


def run(
    cmd: list[str],
    *,
    check: bool = False,
    capture: bool = True,
    timeout: int | None = None,
    env: dict[str, str] | None = None,
) -> CommandResult:
    """Run a command and return the result."""
    import os

    # Merge provided env with current environment
    run_env = None
    if env:
        run_env = os.environ.copy()
        run_env.update(env)

    try:
        result = subprocess.run(
            cmd,
            capture_output=capture,
            text=True,
            timeout=timeout,
            env=run_env,
        )
        return CommandResult(
            returncode=result.returncode,
            stdout=result.stdout if capture else "",
            stderr=result.stderr if capture else "",
        )
    except subprocess.TimeoutExpired:
        return CommandResult(returncode=-1, stdout="", stderr="Command timed out")
    except FileNotFoundError:
        return CommandResult(returncode=-1, stdout="", stderr=f"Command not found: {cmd[0]}")


def run_sudo(cmd: list[str], **kwargs) -> CommandResult:
    """Run a command with sudo."""
    return run(["sudo"] + cmd, **kwargs)


def command_exists(cmd: str) -> bool:
    """Check if a command exists in PATH."""
    return shutil.which(cmd) is not None


def require_command(cmd: str) -> None:
    """Raise error if command doesn't exist."""
    if not command_exists(cmd):
        raise RuntimeError(f"Required command not found: {cmd}")
