"""Samba/SMB file sharing commands."""

import getpass
import subprocess
from pathlib import Path

import typer

from mesh.core.config import get_shared_folder
from mesh.core.environment import OSType, detect_os_type
from mesh.utils.output import error, info, ok, section, warn
from mesh.utils.process import command_exists, run_sudo
from mesh.utils.ssh import ssh_to_host

app = typer.Typer(
    name="smb",
    help="Samba/SMB file sharing",
    no_args_is_help=True,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _is_tailscale_connected() -> bool:
    """Check if Tailscale is connected."""
    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            import json

            data = json.loads(result.stdout)
            return data.get("BackendState") == "Running"
    except (subprocess.TimeoutExpired, FileNotFoundError, ValueError):
        pass
    return False


def _share_exists_in_testparm(share_name: str) -> bool:
    """Check if a share section already exists via testparm."""
    try:
        result = subprocess.run(
            ["testparm", "-s"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        # testparm outputs section headers as [name]
        for line in result.stdout.splitlines():
            stripped = line.strip()
            if stripped == f"[{share_name}]":
                return True
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return False


def _set_smb_password(user: str, password: str) -> bool:
    """Set Samba password for a user via smbpasswd.

    Uses subprocess directly because run_sudo() does not support input=.
    """
    try:
        result = subprocess.run(
            ["sudo", "smbpasswd", "-a", "-s", user],
            input=f"{password}\n{password}\n",
            text=True,
            capture_output=True,
            timeout=30,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def _systemctl_is_active(service: str) -> bool:
    """Check if a systemd service is active."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", service],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() == "active"
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def _write_systemd_dropin(service: str) -> bool:
    """Create a systemd restart drop-in for the given service.

    Creates /etc/systemd/system/{service}.service.d/10-restart.conf.
    Uses subprocess + sudo tee since Write tool cannot access /etc.
    """
    dropin_dir = f"/etc/systemd/system/{service}.service.d"
    dropin_path = f"{dropin_dir}/10-restart.conf"
    dropin_content = "[Service]\nRestart=on-failure\nRestartSec=5\n"

    # Check if already exists
    if Path(dropin_path).exists():
        return True

    # Create directory
    result = run_sudo(["mkdir", "-p", dropin_dir])
    if not result.success:
        return False

    # Write file via sudo tee
    try:
        proc = subprocess.run(
            ["sudo", "tee", dropin_path],
            input=dropin_content,
            text=True,
            capture_output=True,
            timeout=10,
        )
        return proc.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


@app.command()
def setup_server(
    share: str = typer.Option("shared", "--share", help="Share name"),
    path: str = typer.Option(None, "--path", "-p", help="Share directory path"),
    user: str = typer.Option(None, "--user", "-u", help="SMB user (default: current user)"),
    password: str = typer.Option(
        ..., "--password", prompt=True, hide_input=True, help="SMB password"
    ),
) -> None:
    """Set up Samba server on this Linux host.

    Installs Samba, creates a share, sets a user password,
    configures systemd restart policies, and enables services.

    Idempotent: safe to run multiple times.
    """
    section("SMB Server Setup")

    # --- 1. Check OS is Linux ---
    os_type = detect_os_type()
    if os_type != OSType.UBUNTU:
        error(f"This command requires Ubuntu/Linux, detected: {os_type.value}")
        raise typer.Exit(1)

    # --- 2. Check Tailscale ---
    if command_exists("tailscale"):
        if _is_tailscale_connected():
            ok("Tailscale connected")
        else:
            warn("Tailscale not connected - SMB will work on LAN but mesh IPs won't resolve")
    else:
        warn("Tailscale not installed - SMB will only be available on LAN")

    # --- Resolve defaults ---
    share_path = Path(path) if path else get_shared_folder()
    smb_user = user or getpass.getuser()

    # --- 3. Install Samba ---
    if command_exists("smbd"):
        ok("Samba already installed")
    else:
        info("Installing Samba...")
        run_sudo(
            ["apt-get", "update"],
            env={"DEBIAN_FRONTEND": "noninteractive"},
        )
        result = run_sudo(
            ["apt-get", "install", "-y", "samba"],
            env={"DEBIAN_FRONTEND": "noninteractive"},
        )
        if result.success:
            ok("Samba installed")
        else:
            error(f"Failed to install Samba: {result.stderr}")
            raise typer.Exit(1)

    # --- 4. Create share directory ---
    if share_path.exists():
        ok(f"Share directory exists: {share_path}")
    else:
        info(f"Creating share directory: {share_path}")
        result = run_sudo(["mkdir", "-p", str(share_path)])
        if result.success:
            # Set ownership to the SMB user
            run_sudo(["chown", f"{smb_user}:{smb_user}", str(share_path)])
            run_sudo(["chmod", "2775", str(share_path)])
            ok(f"Created {share_path}")
        else:
            error(f"Failed to create directory: {result.stderr}")
            raise typer.Exit(1)

    # --- 5. Configure share in smb.conf ---
    if _share_exists_in_testparm(share):
        ok(f"Share [{share}] already configured")
    else:
        info(f"Adding [{share}] to /etc/samba/smb.conf...")
        share_config = (
            f"\n[{share}]\n"
            f"   path = {share_path}\n"
            f"   browseable = yes\n"
            f"   read only = no\n"
            f"   guest ok = no\n"
            f"   valid users = {smb_user}\n"
            f"   create mask = 0664\n"
            f"   directory mask = 2775\n"
        )
        try:
            proc = subprocess.run(
                ["sudo", "tee", "-a", "/etc/samba/smb.conf"],
                input=share_config,
                text=True,
                capture_output=True,
                timeout=10,
            )
            if proc.returncode == 0:
                ok(f"Share [{share}] added to smb.conf")
            else:
                error(f"Failed to update smb.conf: {proc.stderr}")
                raise typer.Exit(1)
        except subprocess.TimeoutExpired:
            error("Timed out writing to smb.conf")
            raise typer.Exit(1)

    # --- 6. Set SMB password ---
    info(f"Setting SMB password for user '{smb_user}'...")
    if _set_smb_password(smb_user, password):
        ok(f"SMB password set for '{smb_user}'")
    else:
        error(f"Failed to set SMB password for '{smb_user}'")
        raise typer.Exit(1)

    # --- 7. Check UFW ---
    if command_exists("ufw"):
        try:
            result = subprocess.run(
                ["ufw", "status"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if "active" in result.stdout.lower() and "inactive" not in result.stdout.lower():
                info("UFW active - adding Samba rule...")
                fw_result = run_sudo(["ufw", "allow", "samba"])
                if fw_result.success:
                    ok("Samba allowed through UFW")
                else:
                    warn(f"Failed to add UFW rule: {fw_result.stderr}")
            else:
                info("UFW inactive - no firewall rule needed")
        except (subprocess.TimeoutExpired, FileNotFoundError):
            info("Could not check UFW status")
    else:
        info("UFW not installed - skipping firewall configuration")

    # --- 8. Create systemd drop-ins ---
    for service in ("smbd", "nmbd"):
        if _write_systemd_dropin(service):
            ok(f"Systemd restart drop-in for {service}")
        else:
            warn(f"Failed to create systemd drop-in for {service}")

    # --- 9. Enable and start services ---
    run_sudo(["systemctl", "daemon-reload"])
    for service in ("smbd", "nmbd"):
        result = run_sudo(["systemctl", "enable", "--now", service])
        if result.success:
            ok(f"{service} enabled and started")
        else:
            warn(f"Failed to enable {service}: {result.stderr}")

    # --- 10. Verify ---
    info("Verifying configuration...")
    try:
        result = subprocess.run(
            ["testparm", "-s"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and f"[{share}]" in result.stdout:
            ok("Configuration verified via testparm")
        else:
            warn("testparm did not confirm share - check /etc/samba/smb.conf manually")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        warn("Could not run testparm to verify")

    section("SMB Server Setup Complete")
    info(f"Share: \\\\<this-host>\\{share}")
    info(f"Path: {share_path}")
    info(f"User: {smb_user}")


@app.command()
def add_user(
    user: str = typer.Argument(..., help="Username to add to Samba"),
    password: str = typer.Option(
        ..., "--password", prompt=True, hide_input=True, help="SMB password"
    ),
) -> None:
    """Add or update a Samba user password.

    The user must already exist as a system user.
    """
    section("Add SMB User")

    info(f"Setting SMB password for '{user}'...")
    if _set_smb_password(user, password):
        ok(f"SMB password set for '{user}'")
    else:
        error(f"Failed to set SMB password for '{user}'")
        raise typer.Exit(1)

    # Verify user appears in pdbedit
    info("Verifying user in Samba database...")
    try:
        result = subprocess.run(
            ["sudo", "pdbedit", "-L"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and user in result.stdout:
            ok(f"User '{user}' confirmed in Samba database")
        else:
            warn(f"Could not confirm '{user}' in pdbedit output")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        warn("Could not run pdbedit to verify")


@app.command()
def setup_client(
    host: str = typer.Option(..., "--host", "-h", help="Windows SSH host"),
    port: int = typer.Option(22, "--port", "-p", help="SSH port"),
    server: str = typer.Option(
        ..., "--server", "-s", help="SMB server hostname or IP"
    ),
    share: str = typer.Option("shared", "--share", help="Share name"),
    drive: str = typer.Option("Z:", "--drive", "-d", help="Windows drive letter"),
    user: str = typer.Option(..., "--user", "-u", help="SMB username"),
) -> None:
    """Set up SMB drive mapping on a Windows host via SSH.

    Runs from Linux, connects to Windows via SSH, and generates
    a PowerShell script for drive mapping.
    """
    section("SMB Client Setup")

    # --- 1. Test SSH connectivity ---
    info(f"Testing SSH connectivity to {host}:{port}...")
    success, output = ssh_to_host(host, "echo connected", port=port)
    if not success:
        error(f"Cannot SSH to {host}:{port}: {output}")
        raise typer.Exit(1)
    ok(f"Connected to {host}")

    # --- 2. Test SMB port on server ---
    info(f"Testing SMB connectivity from {host} to {server}:445...")
    smb_test_cmd = (
        f'powershell -Command "'
        f"(Test-NetConnection {server} -Port 445 -WarningAction SilentlyContinue)"
        f'.TcpTestSucceeded"'
    )
    success, output = ssh_to_host(host, smb_test_cmd, port=port)
    if success and "True" in output:
        ok(f"SMB port 445 reachable on {server}")
    else:
        warn(f"SMB port 445 may not be reachable on {server} from {host}")
        info("Continuing anyway - the generated script will retry at runtime")

    # --- 3. Ensure C:\temp exists ---
    info("Ensuring C:\\temp exists on Windows...")
    mkdir_cmd = (
        'powershell -Command "New-Item -Path C:\\temp -ItemType Directory -Force | Out-Null"'
    )
    success, output = ssh_to_host(host, mkdir_cmd, port=port)
    if success:
        ok("C:\\temp ready")
    else:
        warn(f"Could not create C:\\temp: {output}")

    # --- 4. Generate PS1 script ---
    script_path = "C:\\temp\\map-smb-drive.ps1"
    smb_path = f"\\\\{server}\\{share}"
    startup_folder = "$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"

    lines = [
        "# map-smb-drive.ps1 - Generated by mesh smb setup-client",
        f"# Server: {server}",
        f"# Share: {share}",
        f"# Drive: {drive}",
        f"# User: {user}",
        "",
        "$ErrorActionPreference = 'Continue'",
        "",
        "Write-Host '=== SMB Drive Mapping ===' -ForegroundColor Cyan",
        "",
        "# Step 1: Get credentials",
        f"Write-Host 'Enter SMB password for {user}' -ForegroundColor Yellow",
        f"$Cred = Get-Credential -UserName '{user}' -Message 'Enter SMB password'",
        "if (-not $Cred) {",
        "    Write-Host 'Cancelled.' -ForegroundColor Red",
        "    Read-Host 'Press Enter to exit'",
        "    exit 1",
        "}",
        "$Password = $Cred.GetNetworkCredential().Password",
        "",
        "# Step 2: Remove existing mapping",
        f"Write-Host 'Removing existing {drive} mapping...' -ForegroundColor Yellow",
        f"net use {drive} /delete /y 2>$null",
        "",
        "# Step 3: Map drive",
        f"Write-Host 'Mapping {drive} to {smb_path}...' -ForegroundColor Yellow",
        f"$mapResult = net use {drive} {smb_path} /user:{user} $Password /persistent:yes 2>&1",
        "if ($LASTEXITCODE -eq 0) {",
        f"    Write-Host 'SUCCESS: {drive} mapped to {smb_path}' -ForegroundColor Green",
        "} else {",
        f"    Write-Host 'FAILED to map {drive}' -ForegroundColor Red",
        "    Write-Host $mapResult -ForegroundColor Red",
        "    Read-Host 'Press Enter to exit'",
        "    exit 1",
        "}",
        "",
        "# Step 4: Enable linked connections (for elevated processes)",
        "Write-Host 'Setting EnableLinkedConnections...' -ForegroundColor Yellow",
        "$regPath = 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System'",
        "try {",
        "    Set-ItemProperty -Path $regPath -Name 'EnableLinkedConnections' -Value 1 -Type DWord",
        "    Write-Host 'EnableLinkedConnections set' -ForegroundColor Green",
        "} catch {",
        "    Write-Host 'WARNING: Could not set EnableLinkedConnections (run as admin)' -ForegroundColor Yellow",
        "}",
        "",
        "# Step 5: Create reconnect script in Startup folder",
        "Write-Host 'Creating startup reconnect script...' -ForegroundColor Yellow",
        f'$startupPath = "{startup_folder}"',
        "$cmdPath = Join-Path $startupPath 'reconnect-smb.cmd'",
        '$cmdContent = @"',
        "@echo off",
        f"net use {drive} {smb_path} /user:{user} /persistent:yes",
        '"@',
        "try {",
        "    $cmdContent | Set-Content -Path $cmdPath -Force",
        "    Write-Host \"Startup script created: $cmdPath\" -ForegroundColor Green",
        "} catch {",
        "    Write-Host \"WARNING: Could not create startup script: $_\" -ForegroundColor Yellow",
        "}",
        "",
        "Write-Host ''",
        f"Write-Host '{drive} is now mapped to {smb_path}' -ForegroundColor Cyan",
        "Write-Host 'Note: Log off and back on for EnableLinkedConnections to take effect' -ForegroundColor Yellow",
        "Write-Host ''",
        "Read-Host 'Press Enter to exit'",
    ]

    # --- 5. Write script via SSH + stdin pipe ---
    info("Writing PowerShell script to Windows...")
    script_content = "\n".join(lines)
    ps_write_cmd = f"powershell -Command \"$input | Set-Content -Path '{script_path}'\""

    try:
        result = subprocess.run(
            [
                "ssh",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=30",
                "-o", "StrictHostKeyChecking=accept-new",
                "-p", str(port),
                host,
                ps_write_cmd,
            ],
            input=script_content,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            ok(f"Script written to {script_path}")
        else:
            error(f"Failed to write script: {result.stdout + result.stderr}")
            raise typer.Exit(1)
    except subprocess.TimeoutExpired:
        error("Timed out writing script to Windows")
        raise typer.Exit(1)

    # --- 6. Print instructions ---
    section("SMB Client Setup Complete")
    info("Run the following on the Windows desktop (as Administrator):")
    info(f"  powershell -ExecutionPolicy Bypass -File {script_path}")
    info("")
    info("The script will:")
    info(f"  1. Prompt for the SMB password for '{user}'")
    info(f"  2. Map {drive} to {smb_path}")
    info("  3. Set EnableLinkedConnections for elevated process access")
    info("  4. Create a startup script for automatic reconnection")


@app.command()
def status() -> None:
    """Check SMB/Samba status on this host."""
    section("SMB Status")

    os_type = detect_os_type()
    info(f"OS type: {os_type.value}")

    if os_type not in (OSType.UBUNTU, OSType.WSL2):
        warn("SMB status is only supported on Linux")
        info("For Windows, check drive mappings with: net use")
        return

    # Check if Samba is installed
    info("Checking Samba installation...")
    if command_exists("smbd"):
        ok("Samba installed")
    else:
        warn("Samba not installed")
        info("Install with: mesh smb setup-server")
        return

    # Check service status
    info("Checking services...")
    for service in ("smbd", "nmbd"):
        if _systemctl_is_active(service):
            ok(f"{service} is active")
        else:
            warn(f"{service} is not active")
            info(f"Start with: sudo systemctl start {service}")

    # List shares via testparm
    info("Checking shares...")
    try:
        result = subprocess.run(
            ["testparm", "-s"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            shares = []
            for line in result.stdout.splitlines():
                stripped = line.strip()
                if stripped.startswith("[") and stripped.endswith("]"):
                    name = stripped[1:-1]
                    if name not in ("global", "printers", "print$"):
                        shares.append(name)
            if shares:
                ok(f"Shares: {', '.join(shares)}")
            else:
                warn("No user shares configured")
                info("Add a share with: mesh smb setup-server")
        else:
            warn(f"testparm failed: {result.stderr.strip()}")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        warn("Could not run testparm")

    # Check port 445
    info("Checking port 445...")
    try:
        result = subprocess.run(
            ["ss", "-tlnp"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and ":445 " in result.stdout:
            ok("Port 445 is listening")
        else:
            warn("Port 445 is not listening")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        warn("Could not check port 445")

    # Check Tailscale for mesh accessibility
    if command_exists("tailscale"):
        if _is_tailscale_connected():
            ok("Tailscale connected - share accessible via mesh IPs")
        else:
            warn("Tailscale not connected - share only accessible on LAN")
