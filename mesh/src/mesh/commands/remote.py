"""Remote provisioning commands (run from Headscale server to set up clients via SSH)."""

import re
import socket
import subprocess

import typer

from mesh.core.config import get_host, load_hosts
from mesh.core.headscale import create_preauth_key, list_nodes
from mesh.utils.output import error, info, ok, section, warn

app = typer.Typer(
    name="remote",
    help="Remote provisioning via SSH",
    no_args_is_help=True,
)

# Default Headscale port
HEADSCALE_PORT = 8080


def get_local_ip() -> str:
    """Get the local machine's IP address that's routable to other hosts.

    Returns the IP of the default route interface, not localhost.
    """
    try:
        # Connect to a public IP (doesn't actually send data) to find our outbound IP
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        # Fallback: try to get from hostname
        try:
            return socket.gethostbyname(socket.gethostname())
        except socket.gaierror:
            return "127.0.0.1"


def get_default_server_url() -> str:
    """Get the default Headscale server URL using local IP."""
    ip = get_local_ip()
    return f"http://{ip}:{HEADSCALE_PORT}"


# SSH options for non-interactive connections
SSH_OPTS = [
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "StrictHostKeyChecking=accept-new",
]


def ssh_run(host: str, port: int, cmd: str, timeout: int = 120) -> tuple[bool, str]:
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


def detect_remote_os(host: str, port: int) -> str | None:
    """Detect OS type of remote host. Returns 'linux', 'windows', or None."""
    # Try uname first (works on Linux/WSL/MSYS)
    success, output = ssh_run(host, port, "uname -s", timeout=15)
    if success:
        out = output.strip().lower()
        if "linux" in out:
            return "linux"
        if "darwin" in out:
            return "macos"
        # MSYS/Git Bash on Windows reports as MSYS_NT-*
        if "msys" in out or "mingw" in out or "cygwin" in out:
            return "windows"

    # Try Windows-specific command
    success, output = ssh_run(host, port, "echo %OS%", timeout=15)
    if success and "windows" in output.lower():
        return "windows"

    # Try PowerShell as fallback for Windows
    success, output = ssh_run(host, port, 'powershell -Command "$env:OS"', timeout=15)
    if success and "windows" in output.lower():
        return "windows"

    return None


def provision_linux(host: str, port: int, server_url: str, auth_key: str) -> bool:
    """Provision Tailscale on a Linux host."""
    info("Installing Tailscale on Linux...")

    # Check if already installed
    success, _ = ssh_run(host, port, "which tailscale")
    if success:
        ok("Tailscale already installed")
    else:
        # Install via official script
        info("Downloading and running Tailscale installer...")
        success, output = ssh_run(
            host,
            port,
            "curl -fsSL https://tailscale.com/install.sh | sudo sh",
            timeout=180,
        )
        if not success:
            if "password" in output.lower() or "terminal" in output.lower():
                error("sudo requires password - run 'mesh remote prepare' first")
                info(f"  mesh remote prepare {host} -p {port}")
            else:
                error(f"Failed to install Tailscale: {output}")
            return False
        ok("Tailscale installed")

    # Connect to Headscale
    info("Connecting to mesh network...")
    ts_cmd = (
        f"sudo tailscale up --login-server={server_url} "
        f"--authkey={auth_key} --accept-routes --accept-dns=false"
    )
    success, output = ssh_run(host, port, ts_cmd, timeout=60)
    if not success:
        # Check if already connected
        success, status = ssh_run(host, port, "tailscale status")
        if success and server_url.split("//")[1].split(":")[0] in status:
            ok("Already connected to mesh")
        else:
            error(f"Failed to connect: {output}")
            return False
    else:
        ok("Connected to mesh network")

    # Get Tailscale IP
    success, output = ssh_run(host, port, "tailscale ip -4")
    if success:
        info(f"Tailscale IP: {output.strip()}")

    return True


def check_windows_vpn_lan_access(host: str, port: int, server_ip: str) -> bool:
    """Check if VPN is blocking LAN access to the Headscale server.

    Returns True if there's a routing problem (VPN blocking LAN).
    """
    # Just check if we can reach the Headscale server directly
    # This is the definitive test - if curl works, we're good
    cmd = (
        f"powershell -Command \"curl.exe -s -o NUL -w '%{{http_code}}' "
        f'-m 5 http://{server_ip}:8080/health"'
    )
    success, output = ssh_run(host, port, cmd, timeout=10)
    return not success or "200" not in output


def check_windows_vpn_conflicts(host: str, port: int) -> list[str]:
    """Check for VPN software that conflicts with Tailscale on Windows.

    Returns list of detected conflicting VPNs.
    """
    conflicts = []

    # Check for NordVPN (uses WireGuard on port 41641)
    cmd = (
        'powershell -Command "Get-Service NordVPN* 2>$null | Select-Object -ExpandProperty Status"'
    )
    success, output = ssh_run(host, port, cmd, timeout=10)
    if success and "Running" in output:
        conflicts.append("NordVPN")

    # Check for NordLynx adapter (NordVPN WireGuard)
    cmd = (
        'powershell -Command "'
        'Get-NetAdapter -Name NordLynx 2>$null | Select-Object -ExpandProperty Status"'
    )
    success, output = ssh_run(host, port, cmd, timeout=10)
    if success and "Up" in output:
        conflicts.append("NordLynx (NordVPN WireGuard)")

    # Check for other common VPNs that might conflict
    vpn_services = [
        ("ExpressVPN", "ExpressVPN*"),
        ("Surfshark", "Surfshark*"),
        ("CyberGhost", "CyberGhost*"),
        ("Private Internet Access", "pia*"),
    ]
    for name, pattern in vpn_services:
        cmd = (
            f'powershell -Command "Get-Service {pattern} 2>$null | Where-Object Status -eq Running"'
        )
        success, output = ssh_run(host, port, cmd, timeout=10)
        if success and output.strip():
            conflicts.append(name)

    return conflicts


def provision_windows(host: str, port: int, server_url: str, auth_key: str) -> bool:
    """Provision Tailscale on a Windows host.

    NOTE: Due to Windows Session 0 isolation, SSH sessions cannot communicate
    with the Tailscale service IPN backend. This function will:
    1. Install Tailscale if needed
    2. Configure registry settings
    3. Generate a PowerShell script for manual execution

    The user must run the generated script locally on Windows.
    """
    info("Configuring Tailscale on Windows...")
    ts_exe = "C:\\Program Files\\Tailscale\\tailscale.exe"

    # Extract server IP from URL for connectivity checks
    server_match = re.search(r"://([^:/]+)", server_url)
    server_ip = server_match.group(1) if server_match else ""

    # Check for VPN conflicts FIRST
    info("Checking for VPN conflicts...")
    conflicts = check_windows_vpn_conflicts(host, port)
    if conflicts:
        warn(f"Detected conflicting VPN(s): {', '.join(conflicts)}")
        warn("These VPNs may block Tailscale port 41641 or interfere with WireGuard.")
        # Check if VPN is blocking LAN access to our server
        if server_ip and check_windows_vpn_lan_access(host, port, server_ip):
            error("VPN is blocking access to Headscale server!")
            error(f"The Tailscale service cannot reach {server_ip}:8080 via the VPN tunnel.")
            info("")
            info("REQUIRED: Enable 'Allow LAN access' in NordVPN settings, or")
            info("          temporarily disconnect the VPN to complete mesh setup.")
            info("")
            return False
        info("Consider disconnecting them before joining the mesh network.")
        info("")

    # Check if Tailscale is installed
    check_cmd = f"powershell -Command \"Test-Path '{ts_exe}'\""
    success, output = ssh_run(host, port, check_cmd)
    if not success or "False" in output:
        # Try to install via winget (use --source winget to avoid msstore cert issues)
        info("Tailscale not found, attempting winget install...")
        install_cmd = (
            'powershell -Command "winget install --id Tailscale.Tailscale '
            '--source winget --accept-source-agreements --accept-package-agreements --silent"'
        )
        success, output = ssh_run(host, port, install_cmd, timeout=180)
        if not success and "already installed" not in output.lower():
            error("Failed to install Tailscale via winget")
            info("Install manually from: https://tailscale.com/download/windows")
            return False
        ok("Tailscale installed via winget")
        # Wait for service to start after fresh install
        info("Waiting for Tailscale service to initialize...")
        ssh_run(host, port, 'powershell -Command "Start-Sleep 5"', timeout=15)
    else:
        ok("Tailscale is installed")

    # Configure registry for unattended connection
    # This sets up the connection parameters so the service knows where to connect
    info("Configuring Tailscale registry settings...")
    registry_cmds = [
        "$regPath = 'HKLM:\\SOFTWARE\\Tailscale IPN'",
        "if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }",
        f"Set-ItemProperty -Path $regPath -Name 'LoginURL' -Value '{server_url}'",
        f"Set-ItemProperty -Path $regPath -Name 'AuthKey' -Value '{auth_key}'",
        "Set-ItemProperty -Path $regPath -Name 'UnattendedMode' -Value 'always'",
    ]
    reg_cmd = f'powershell -Command "{"; ".join(registry_cmds)}"'
    success, output = ssh_run(host, port, reg_cmd, timeout=15)
    if success:
        ok("Registry configured for mesh connection")
    else:
        warn(f"Registry configuration may have issues: {output}")

    # NOTE: Due to Windows Session 0 isolation, SSH sessions CANNOT communicate
    # with the Tailscale IPN backend. Running `tailscale status` or `tailscale up`
    # via SSH actually DISCONNECTS the service. We must generate a script for
    # the user to run locally in an interactive Windows session.
    #
    # The generated script will:
    # 1. Stop any tray app that might interfere
    # 2. Restart the service cleanly
    # 3. Run tailscale up with auth key
    # 4. Verify connection

    script_path = "C:\\temp\\join-mesh.ps1"
    log_path = "C:\\temp\\join-mesh.log"

    info("Creating connection script for manual execution...")

    # Build header lines (including optional VPN warning)
    header_lines = [
        "# join-mesh.ps1 - Generated by mesh remote provision",
        f"# Server: {server_url}",
        f"# Log: {log_path}",
    ]
    if conflicts:
        header_lines.append(f"# WARNING: Detected conflicting VPN(s): {', '.join(conflicts)}")
        header_lines.append("# Consider disconnecting before running.")
    header_lines.append("")

    lines = header_lines + [
        "$ErrorActionPreference = 'Continue'",
        f"$TailscaleExe = '{ts_exe}'",
        f"$ServerUrl = '{server_url}'",
        f"$AuthKey = '{auth_key}'",
        f"$LogFile = '{log_path}'",
        "",
        "# Start transcript logging",
        "Start-Transcript -Path $LogFile -Force",
        "",
        # Log function just outputs to console - transcript captures it automatically
        "function Log($msg) { $ts = Get-Date -Format 'HH:mm:ss'; Write-Host \"[$ts] $msg\" }",
        "",
        "Write-Host '=== Joining Mesh Network ===' -ForegroundColor Cyan",
        'Log "Starting mesh join - Server: $ServerUrl"',
        "",
        "# Step 1: Stop any running Tailscale processes",
        "Write-Host '[1/5] Stopping Tailscale processes...' -ForegroundColor Yellow",
        "Log 'Stopping tailscale-ipn process...'",
        "Stop-Process -Name 'tailscale-ipn' -Force -ErrorAction SilentlyContinue",
        "Log 'Stopping Tailscale service...'",
        "Stop-Service Tailscale -Force -ErrorAction SilentlyContinue",
        "Start-Sleep 2",
        "Log 'Step 1 complete'",
        "",
        "# Step 2: Configure registry for this mesh",
        "Write-Host '[2/5] Configuring mesh settings...' -ForegroundColor Yellow",
        "$regPath = 'HKLM:\\SOFTWARE\\Tailscale IPN'",
        'Log "Setting registry: $regPath"',
        "if (!(Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }",
        "Set-ItemProperty -Path $regPath -Name 'LoginURL' -Value $ServerUrl",
        "Set-ItemProperty -Path $regPath -Name 'UnattendedMode' -Value 'always'",
        "Log 'Step 2 complete'",
        "",
        "# Step 3: Start fresh service",
        "Write-Host '[3/5] Starting Tailscale service...' -ForegroundColor Yellow",
        "Log 'Starting Tailscale service...'",
        "Start-Service Tailscale",
        "Start-Sleep 3",
        "$svcStatus = (Get-Service Tailscale).Status",
        'Log "Service status: $svcStatus"',
        "Log 'Step 3 complete'",
        "",
        "# Step 4: Connect to mesh",
        "Write-Host '[4/5] Connecting to mesh network...' -ForegroundColor Yellow",
        "Log 'Running tailscale up (timeout 30s)...'",
        'Log "Command: $TailscaleExe up --login-server=$ServerUrl '
        '--authkey=<redacted> --accept-routes --unattended --reset --timeout=30s"',
        "",
        "# Capture output and run with job to detect hangs",
        "$upOutput = & $TailscaleExe up --login-server=$ServerUrl --authkey=$AuthKey "
        "--accept-routes --unattended --reset --timeout=30s 2>&1 | Out-String",
        "$connectResult = $LASTEXITCODE",
        'Log "tailscale up exit code: $connectResult"',
        'Log "tailscale up output: $upOutput"',
        "",
        "# Step 5: Verify connection",
        "Write-Host '[5/5] Verifying connection...' -ForegroundColor Yellow",
        "Start-Sleep 2",
        "Log 'Checking tailscale status...'",
        "$status = & $TailscaleExe status 2>&1 | Out-String",
        'Log "Status output: $status"',
        "",
        "Write-Host ''",
        "if ($connectResult -eq 0 -and $status -notmatch 'Logged out') {",
        "    Write-Host 'SUCCESS: Connected to mesh network!' -ForegroundColor Green",
        "    Log 'SUCCESS'",
        "    Write-Host ''",
        "    & $TailscaleExe status",
        "} else {",
        "    Write-Host 'FAILED: Could not connect to mesh' -ForegroundColor Red",
        '    Write-Host "Status: $status" -ForegroundColor Red',
        '    Log "FAILED - exit code: $connectResult"',
        "}",
        "",
        "Stop-Transcript",
        f"Write-Host 'Log saved to: {log_path}' -ForegroundColor Gray",
        "Write-Host ''",
        "Read-Host 'Press Enter to exit'",
    ]

    # Write script content by piping via stdin (avoids command-line length limits)
    script_content = "\n".join(lines)

    # Use subprocess directly with stdin
    ps_write_cmd = f"powershell -Command \"$input | Set-Content -Path '{script_path}'\""
    ssh_cmd = ["ssh"] + SSH_OPTS + ["-p", str(port), host, ps_write_cmd]
    # First ensure temp directory exists
    mkdir_cmd = (
        "powershell -Command \"New-Item -Path 'C:\\temp' -ItemType Directory -Force | Out-Null\""
    )
    ssh_run(host, port, mkdir_cmd)

    try:
        result = subprocess.run(
            ssh_cmd,
            input=script_content,
            capture_output=True,
            text=True,
            timeout=30,
        )
        success = result.returncode == 0
    except subprocess.TimeoutExpired:
        success = False

    if success:
        ok("Script created on Windows")
        info("")
        info("MANUAL STEP REQUIRED - Run in PowerShell on Windows:")
        info("─" * 60)
        info(f"  powershell -ExecutionPolicy Bypass -File {script_path}")
        info("─" * 60)
        info("Or right-click the file and select 'Run with PowerShell'")
        info("")
        info(f"Log will be saved to: {log_path}")
        if conflicts:
            warn(f"VPN conflict detected: {', '.join(conflicts)}")
            info("The script may fail if the VPN is using WireGuard port 41641.")
    else:
        # Fallback to showing command if script creation failed
        warn("Could not create script on Windows")
        info("")
        info("MANUAL STEP: Run in PowerShell on Windows:")
        info("─" * 60)
        info(f'& "{ts_exe}" up --login-server={server_url} `')
        info(f"  --authkey={auth_key} --accept-routes --unattended")
        info("─" * 60)

    info("")
    info("Why: Windows Session 0 isolation prevents SSH from reaching Tailscale service.")
    info("After running the script, re-run 'mesh remote status windows' to verify.")
    # Return False to indicate manual step needed (expected for Windows)
    return False


def _extract_hostname(host: str) -> str:
    """Extract hostname from user@host or host.domain format."""
    # Remove user@ prefix if present
    if "@" in host:
        host = host.split("@")[-1]
    # Remove domain suffix if present
    return host.split(".")[0].lower()


def _is_already_provisioned(hostname: str, user: str = "mesh") -> bool:
    """Check if a host is already provisioned in the mesh.

    Args:
        hostname: Hostname to check
        user: Headscale user/namespace

    Returns:
        True if host is already in Headscale nodes list.
    """
    try:
        nodes = list_nodes(user=user)
        node_names = {n.get("givenName", "").lower() for n in nodes}
        return hostname.lower() in node_names
    except Exception:
        return False


@app.command()
def provision(
    host: str = typer.Argument(..., help="Remote host (user@hostname or hostname)"),
    port: int = typer.Option(22, "--port", "-p", help="SSH port"),
    server: str | None = typer.Option(
        None, "--server", "-s", help="Headscale server URL (auto-detects local IP)"
    ),
    user: str = typer.Option("mesh", "--user", "-u", help="Headscale user/namespace"),
    skip_syncthing: bool = typer.Option(
        False, "--skip-syncthing", help="Skip Syncthing installation"
    ),
    force: bool = typer.Option(
        False, "--force", "-f", help="Force re-provision even if already in mesh"
    ),
) -> None:
    """Provision a remote host to join the mesh network.

    This command:
    - Connects to the remote host via SSH
    - Detects the OS (Linux or Windows)
    - Checks if already provisioned (idempotent)
    - Generates a Headscale auth key
    - Installs/configures Tailscale to join the mesh
    - Optionally installs Syncthing

    Examples:
        mesh remote provision user@host.local
        mesh remote provision user@host.local --port 2222  # WSL
        mesh remote provision ubu1  # Uses host registry if configured
    """
    # Auto-detect server URL if not provided
    if server is None:
        server = get_default_server_url()
        info(f"Using Headscale server: {server}")
    # Check if host is in registry (allows short names like "ubu1")
    # Preserve original name for idempotency check before resolving to IP
    original_name = host
    registered_host = get_host(host)
    if registered_host and "@" not in host:
        info(f"Using registered host: {registered_host.ip}:{registered_host.port}")
        host = f"{registered_host.user}@{registered_host.ip}"
        port = registered_host.port

    section(f"Provisioning {host}:{port}")

    # Use original registry name for idempotency, or extract from host string
    hostname = original_name if registered_host else _extract_hostname(host)

    # Check if already provisioned (unless --force)
    if not force and _is_already_provisioned(hostname, user):
        ok(f"{hostname} is already provisioned in the mesh")
        info("Use --force to re-provision anyway")
        return

    # Test SSH connectivity
    info("Testing SSH connectivity...")
    success, output = ssh_run(host, port, "echo connected")
    if not success:
        error(f"Cannot connect to {host}:{port}")
        error(f"SSH error: {output}")
        raise typer.Exit(1)
    ok("SSH connection successful")

    # Detect OS
    info("Detecting remote OS...")
    os_type = detect_remote_os(host, port)
    if not os_type:
        error("Could not detect remote OS")
        raise typer.Exit(1)
    ok(f"Detected OS: {os_type}")

    # Generate auth key
    info("Generating Headscale auth key...")
    auth_key = create_preauth_key(user)
    if not auth_key:
        error("Failed to generate auth key")
        info("Ensure Headscale is running: sudo systemctl status headscale")
        raise typer.Exit(1)
    ok("Auth key generated")

    # Provision based on OS
    if os_type == "linux":
        success = provision_linux(host, port, server, auth_key)
    elif os_type == "windows":
        success = provision_windows(host, port, server, auth_key)
    else:
        error(f"Unsupported OS: {os_type}")
        raise typer.Exit(1)

    if not success:
        if os_type == "windows":
            # Windows provisioning requires manual step - not a failure
            section("Windows Setup Incomplete")
            warn("Manual step required to complete Windows provisioning.")
            warn("Run the PowerShell script shown above on Windows.")
            raise typer.Exit(0)  # Exit 0 because automated part succeeded
        else:
            error("Provisioning failed")
            raise typer.Exit(1)

    # Install Syncthing (Linux only for now)
    if not skip_syncthing and os_type == "linux":
        info("Installing Syncthing...")
        success, _ = ssh_run(host, port, "which syncthing")
        if success:
            ok("Syncthing already installed")
        else:
            # Install via apt
            success, output = ssh_run(
                host,
                port,
                "sudo apt-get update && sudo apt-get install -y syncthing",
                timeout=180,
            )
            if success:
                ok("Syncthing installed")
            else:
                warn(f"Could not install Syncthing: {output}")

    section("Provisioning Complete")
    ok(f"{host} is now part of the mesh network")


@app.command()
def status(
    host: str = typer.Argument(..., help="Remote host (user@hostname or hostname)"),
    port: int = typer.Option(22, "--port", "-p", help="SSH port"),
) -> None:
    """Check mesh status of a remote host."""
    section(f"Status: {host}:{port}")

    # Test SSH
    success, _ = ssh_run(host, port, "echo connected")
    if not success:
        error(f"Cannot connect to {host}:{port}")
        raise typer.Exit(1)
    ok("SSH connection successful")

    # Detect OS
    os_type = detect_remote_os(host, port)
    info(f"OS: {os_type or 'unknown'}")

    # Check Tailscale
    info("Checking Tailscale...")
    if os_type == "linux":
        success, output = ssh_run(host, port, "tailscale status")
        if success:
            ok("Tailscale connected")
            # Get IP
            success, ip = ssh_run(host, port, "tailscale ip -4")
            if success:
                info(f"Tailscale IP: {ip.strip()}")
        else:
            warn("Tailscale not connected or not installed")
    elif os_type == "windows":
        success, output = ssh_run(
            host,
            port,
            'powershell -Command "& \\"C:\\Program Files\\Tailscale\\tailscale.exe\\" status"',
        )
        if success and "100.64" in output:
            ok("Tailscale connected")
        else:
            warn(f"Tailscale status: {output.strip()}")

    # Check Syncthing (Linux only)
    if os_type == "linux":
        info("Checking Syncthing...")
        success, _ = ssh_run(host, port, "which syncthing")
        if success:
            ok("Syncthing installed")
            # Check if running
            success, _ = ssh_run(host, port, "pgrep syncthing")
            if success:
                ok("Syncthing running")
            else:
                warn("Syncthing not running")
        else:
            warn("Syncthing not installed")


@app.command(name="provision-all")
def provision_all(
    server: str | None = typer.Option(
        None, "--server", "-s", help="Headscale server URL (auto-detects local IP)"
    ),
    user: str = typer.Option("mesh", "--user", "-u", help="Headscale user/namespace"),
    force: bool = typer.Option(
        False, "--force", "-f", help="Force re-provision even if already in mesh"
    ),
) -> None:
    """Provision all hosts from the registry.

    Uses hosts from ~/.config/mesh/hosts.yaml.
    Add hosts first with: mesh host add <name> --ip <IP>

    Skips hosts that are already provisioned (use --force to override).
    """
    # Auto-detect server URL if not provided
    if server is None:
        server = get_default_server_url()
        info(f"Using Headscale server: {server}")

    section("Provisioning All Mesh Hosts")

    # Load hosts from registry
    registry = load_hosts()
    if not registry:
        error("No hosts in registry")
        info("Add hosts first: mesh host add <name> --ip <IP>")
        raise typer.Exit(1)

    # Build hosts list from registry
    hosts = [(f"{h.user}@{h.ip}", h.port, h.name) for h in registry.values()]
    info(f"Found {len(hosts)} host(s) in registry")

    results = []
    for host, port, label in hosts:
        info(f"\n--- {label} ({host}:{port}) ---")
        try:
            # Check if already provisioned (unless --force)
            if not force and _is_already_provisioned(label, user):
                ok(f"{label} already provisioned, skipping")
                results.append((label, True, "already provisioned", None))
                continue

            # Test connectivity first
            success, _ = ssh_run(host, port, "echo connected", timeout=10)
            if not success:
                warn(f"Cannot reach {label}, skipping")
                results.append((label, False, "unreachable", None))
                continue

            # Detect OS
            os_type = detect_remote_os(host, port)
            if not os_type:
                warn(f"Cannot detect OS for {label}, skipping")
                results.append((label, False, "unknown OS", None))
                continue

            # Generate auth key for this host
            auth_key = create_preauth_key(user)
            if not auth_key:
                warn("Could not generate auth key, skipping")
                results.append((label, False, "no auth key", None))
                continue

            # Provision
            if os_type == "linux":
                success = provision_linux(host, port, server, auth_key)
            elif os_type == "windows":
                success = provision_windows(host, port, server, auth_key)
            else:
                success = False

            results.append((label, success, "provisioned" if success else "failed", os_type))

        except Exception as e:
            results.append((label, False, str(e), None))

    # Summary
    section("Provisioning Summary")
    windows_failed = False
    for item in results:
        label, success, status = item[0], item[1], item[2]
        detected_os = item[3] if len(item) > 3 else None
        if success:
            ok(f"{label}: {status}")
        else:
            warn(f"{label}: {status}")
            if detected_os == "windows":
                windows_failed = True

    if windows_failed:
        info("")
        info("NOTE: Windows requires manual step due to IPN session isolation.")
        info("See the instructions printed above to complete Windows setup.")

    # Show final mesh status
    info("\nHeadscale nodes:")
    subprocess.run(["sudo", "headscale", "nodes", "list"], timeout=10)


@app.command()
def prepare(
    host: str = typer.Argument(..., help="Remote host (user@hostname)"),
    port: int = typer.Option(22, "--port", "-p", help="SSH port"),
) -> None:
    """Prepare a Linux host for non-interactive provisioning.

    This command configures passwordless sudo for mesh-related commands.
    Run this ONCE before using 'provision' commands.

    Requires interactive SSH (will prompt for password).
    """
    section(f"Preparing {host}:{port}")

    # This uses interactive SSH (no BatchMode) to allow sudo password input
    ssh_cmd = ["ssh", "-t", "-p", str(port), host]

    # The sudoers entry allows specific commands without password
    sudoers_content = (
        "# Mesh network provisioning - passwordless sudo for specific commands\\n"
        "%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt-get update*\\n"
        "%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt-get install*\\n"
        "%sudo ALL=(ALL) NOPASSWD: /usr/bin/tailscale*\\n"
        "%sudo ALL=(ALL) NOPASSWD: /usr/sbin/tailscale*\\n"
        "%sudo ALL=(ALL) NOPASSWD: /bin/systemctl * tailscaled*\\n"
    )

    info("Configuring passwordless sudo for mesh commands...")
    info("(You may be prompted for your password)")

    # Create sudoers.d entry
    setup_cmd = (
        f'echo -e "{sudoers_content}" | '
        "sudo tee /etc/sudoers.d/mesh-provisioning > /dev/null && "
        "sudo chmod 440 /etc/sudoers.d/mesh-provisioning && "
        "sudo visudo -c"
    )

    result = subprocess.run(
        ssh_cmd + [setup_cmd],
        timeout=60,
    )

    if result.returncode == 0:
        ok("Passwordless sudo configured for mesh commands")
        info("You can now run: mesh remote provision " + host)
    else:
        error("Failed to configure sudo")
        info("Try running manually:")
        info(f"  ssh {host}")
        info("  sudo visudo")
        info("  # Add: %sudo ALL=(ALL) NOPASSWD: /usr/bin/tailscale*")
        raise typer.Exit(1)
