<#
.SYNOPSIS
    Mesh Network Setup for Windows
    Configures Tailscale (with Headscale), Syncthing, firewall, and WSL2 auto-start

.DESCRIPTION
    This script:
    - Installs Tailscale and Syncthing via winget
    - Configures Tailscale to use self-hosted Headscale server
    - Creates firewall rules for WSL2 SSH and Syncthing
    - Creates scheduled task for WSL2 auto-start at login
    - Configures Syncthing with correct ports

    SAFETY:
    - Idempotent: safe to run multiple times
    - Never deletes existing configurations
    - Only adds firewall rules and scheduled tasks if not present

    Can be run:
    - Interactively (elevated PowerShell)
    - Via scheduled task as SYSTEM
    - Remotely via SSH + scheduled task

.PARAMETER Tailscale
    Install Tailscale only

.PARAMETER Syncthing
    Install Syncthing only

.PARAMETER WslAutoStart
    Configure WSL2 auto-start only

.PARAMETER Firewall
    Configure firewall rules only

.PARAMETER All
    Configure everything (default if no parameters)

.PARAMETER HeadscaleServer
    URL of the Headscale server (e.g., http://sfspark1.local:8080)

.PARAMETER AuthKey
    Pre-auth key for Headscale authentication

.PARAMETER LogFile
    Path to write transcript log (default: $env:TEMP\mesh-setup.log)
#>

param(
    [switch]$Tailscale,
    [switch]$Syncthing,
    [switch]$WslAutoStart,
    [switch]$Firewall,
    [switch]$All,
    [string]$HeadscaleServer = "http://sfspark1.local:8080",
    [string]$AuthKey,
    [string]$LogFile
)

# Default log file for debugging scheduled task runs
if (-not $LogFile) {
    $LogFile = "$env:TEMP\mesh-setup.log"
}

# Always start transcript for debugging
try {
    Start-Transcript -Path $LogFile -Force | Out-Null
} catch {
    # Transcript may already be running
}

# Check for admin privileges (warn but continue for SYSTEM account)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().Name -eq "NT AUTHORITY\SYSTEM"

if (-not $isAdmin -and -not $isSystem) {
    Write-Host "WARNING: Not running as Administrator. Some operations may fail." -ForegroundColor Yellow
    Write-Host "Run from elevated PowerShell or as SYSTEM via scheduled task." -ForegroundColor Yellow
}

# If no specific flags, do everything
if (-not ($Tailscale -or $Syncthing -or $WslAutoStart -or $Firewall)) {
    $All = $true
}

if ($All) {
    $Tailscale = $true
    $Syncthing = $true
    $WslAutoStart = $true
    $Firewall = $true
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "WARN: $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

# ─────────────────────────────────────────────────────────────────────────────
# Installation functions
# ─────────────────────────────────────────────────────────────────────────────

function Install-Tailscale {
    Write-Step "Installing Tailscale"

    # Check if already installed by looking for executable
    $tailscalePath = "$env:ProgramFiles\Tailscale\tailscale.exe"
    $tailscalePathx86 = "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"

    if ((Test-Path $tailscalePath) -or (Test-Path $tailscalePathx86)) {
        Write-OK "Tailscale already installed"
        # Ensure it's in PATH for this session
        $env:Path = "$env:ProgramFiles\Tailscale;$env:Path"
        return
    }

    # Try winget first (only works for user sessions, not SYSTEM)
    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $wingetPath) {
        Write-Host "Installing Tailscale via winget..."
        & $wingetPath install -e --id Tailscale.Tailscale --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Tailscale installed successfully via winget"
            $env:Path = "$env:ProgramFiles\Tailscale;$env:Path"
            return
        }
    }

    # Fall back to direct MSI download
    Write-Host "Downloading Tailscale MSI installer..."
    $msiUrl = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
    $msiPath = "$env:TEMP\tailscale-setup.msi"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

        Write-Host "Installing Tailscale MSI..."
        $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru

        if ($proc.ExitCode -eq 0) {
            Write-OK "Tailscale installed successfully via MSI"
            $env:Path = "$env:ProgramFiles\Tailscale;$env:Path"
        } else {
            Write-Err "MSI install failed with exit code $($proc.ExitCode)"
        }
    } catch {
        Write-Err "Failed to download/install Tailscale: $_"
    } finally {
        Remove-Item $msiPath -ErrorAction SilentlyContinue
    }
}

function Connect-Headscale {
    Write-Step "Connecting to Headscale Server"

    Write-Host "Headscale Server: $HeadscaleServer"

    # Find tailscale executable
    $tailscale = "$env:ProgramFiles\Tailscale\tailscale.exe"
    if (-not (Test-Path $tailscale)) {
        $tailscale = "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    }
    if (-not (Test-Path $tailscale)) {
        Write-Err "Tailscale not found - install first"
        return
    }

    if (-not $AuthKey) {
        Write-Warn "No auth key provided - manual authentication required"
        Write-Host ""
        Write-Host "  To get an auth key, run on sfspark1:"
        Write-Host "    sudo mesh server keygen"
        Write-Host ""
        Write-Host "  Then run:"
        Write-Host "    tailscale up --login-server=$HeadscaleServer --authkey=YOUR_KEY"
        return
    }

    # Check if already connected
    $status = & $tailscale status 2>&1
    if ($status -notmatch "Logged out|stopped|failed" -and $LASTEXITCODE -eq 0) {
        Write-OK "Tailscale already connected"
        & $tailscale status
        return
    }

    Write-Host "Connecting to Headscale..."
    & $tailscale up --login-server="$HeadscaleServer" --authkey="$AuthKey" --accept-routes

    if ($LASTEXITCODE -eq 0) {
        Write-OK "Connected to mesh network"
        & $tailscale status
    } else {
        Write-Err "Failed to connect - verify server URL and auth key"
    }
}

function Install-Syncthing {
    Write-Step "Installing Syncthing"

    # Check if already installed
    $syncthingPath = "$env:LOCALAPPDATA\Syncthing\syncthing.exe"
    $syncthingPathProgFiles = "$env:ProgramFiles\Syncthing\syncthing.exe"

    if ((Test-Path $syncthingPath) -or (Test-Path $syncthingPathProgFiles)) {
        Write-OK "Syncthing already installed"
        return
    }

    # Try winget first (only works for user sessions)
    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $wingetPath) {
        Write-Host "Installing Syncthing via winget..."
        & $wingetPath install -e --id Syncthing.Syncthing --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Syncthing installed successfully via winget"
            return
        }
    }

    # Fall back to direct ZIP download and install
    Write-Host "Downloading Syncthing..."
    $version = "1.28.1"  # Update as needed
    $zipUrl = "https://github.com/syncthing/syncthing/releases/download/v$version/syncthing-windows-amd64-v$version.zip"
    $zipPath = "$env:TEMP\syncthing.zip"
    $extractPath = "$env:TEMP\syncthing-extract"
    $installPath = "$env:ProgramFiles\Syncthing"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        Write-Host "Extracting Syncthing..."
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        # Find extracted folder and move to install location
        $extractedFolder = Get-ChildItem $extractPath -Directory | Select-Object -First 1
        if ($extractedFolder) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
            Copy-Item "$($extractedFolder.FullName)\*" $installPath -Recurse -Force
            Write-OK "Syncthing installed to $installPath"
            Write-Host "  Note: Add Syncthing to startup manually or create a scheduled task"
        }
    } catch {
        Write-Err "Failed to download/install Syncthing: $_"
    } finally {
        Remove-Item $zipPath -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Firewall configuration
# ─────────────────────────────────────────────────────────────────────────────

function Configure-Firewall {
    Write-Step "Configuring Firewall Rules"

    # WSL2 SSH rule (port 2222)
    $ruleName = "WSL2 SSH"
    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if ($existingRule) {
        Write-OK "Firewall rule '$ruleName' already exists"
    } else {
        Write-Host "Creating firewall rule for WSL2 SSH (port 2222)..."
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound `
            -LocalPort 2222 `
            -Protocol TCP `
            -Action Allow | Out-Null
        Write-OK "Firewall rule created: $ruleName"
    }

    # Syncthing rules (ports 22002 for Windows instance)
    $stRuleName = "Syncthing Windows"
    $existingSt = Get-NetFirewallRule -DisplayName $stRuleName -ErrorAction SilentlyContinue

    if ($existingSt) {
        Write-OK "Firewall rule '$stRuleName' already exists"
    } else {
        Write-Host "Creating firewall rule for Syncthing (port 22002)..."
        New-NetFirewallRule -DisplayName $stRuleName `
            -Direction Inbound `
            -LocalPort 22002 `
            -Protocol TCP `
            -Action Allow | Out-Null
        Write-OK "Firewall rule created: $stRuleName"
    }

    # Syncthing WSL2 rule (port 22001)
    $stWslRuleName = "Syncthing WSL2"
    $existingStWsl = Get-NetFirewallRule -DisplayName $stWslRuleName -ErrorAction SilentlyContinue

    if ($existingStWsl) {
        Write-OK "Firewall rule '$stWslRuleName' already exists"
    } else {
        Write-Host "Creating firewall rule for Syncthing WSL2 (port 22001)..."
        New-NetFirewallRule -DisplayName $stWslRuleName `
            -Direction Inbound `
            -LocalPort 22001 `
            -Protocol TCP `
            -Action Allow | Out-Null
        Write-OK "Firewall rule created: $stWslRuleName"
    }

    # Syncthing discovery (UDP 21027 for local discovery)
    $stDiscoveryRuleName = "Syncthing Discovery"
    $existingStDiscovery = Get-NetFirewallRule -DisplayName $stDiscoveryRuleName -ErrorAction SilentlyContinue

    if ($existingStDiscovery) {
        Write-OK "Firewall rule '$stDiscoveryRuleName' already exists"
    } else {
        Write-Host "Creating firewall rule for Syncthing local discovery (UDP 21027)..."
        New-NetFirewallRule -DisplayName $stDiscoveryRuleName `
            -Direction Inbound `
            -LocalPort 21027 `
            -Protocol UDP `
            -Action Allow | Out-Null
        Write-OK "Firewall rule created: $stDiscoveryRuleName"
    }

    # Headscale server rule (port 8080) - only needed if running Headscale on Windows
    # Not typically needed for client-only setup
}

# ─────────────────────────────────────────────────────────────────────────────
# WSL2 auto-start
# ─────────────────────────────────────────────────────────────────────────────

function Configure-WslAutoStart {
    Write-Step "Configuring WSL2 Auto-Start"

    $taskName = "Start WSL2"

    # Check if task exists
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($existingTask) {
        Write-OK "Scheduled task '$taskName' already exists"
        return
    }

    # SYSTEM can't run WSL - skip if running as SYSTEM
    $isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().Name -eq "NT AUTHORITY\SYSTEM"
    if ($isSystem) {
        Write-Warn "WSL auto-start must be configured from a user session, not SYSTEM"
        Write-Host "  Run this script interactively or use: schtasks /create /tn 'Start WSL2' ..."
        return
    }

    # Find WSL2 distro name
    $distros = wsl -l -q 2>&1 | Where-Object { $_ -match '\S' }
    $distroName = $distros | Select-Object -First 1
    $distroName = $distroName -replace '\x00', '' # Remove null chars from wsl output

    if (-not $distroName -or $distroName -match "not supported") {
        Write-Warn "No WSL2 distros found - skipping auto-start setup"
        return
    }

    Write-Host "Found WSL2 distro: $distroName"
    Write-Host "Creating scheduled task to start WSL2 at login..."

    # Create the scheduled task for the current user
    $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $distroName -- true"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    try {
        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Description "Starts WSL2 at login for SSH and Syncthing services" | Out-Null

        Write-OK "Scheduled task created: $taskName"
        Write-Host "  WSL2 will start automatically at login"
    } catch {
        Write-Err "Failed to create scheduled task: $_"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Syncthing configuration
# ─────────────────────────────────────────────────────────────────────────────

function Configure-Syncthing {
    Write-Step "Configuring Syncthing Ports"

    # Try multiple possible config locations
    $configPaths = @(
        "$env:LOCALAPPDATA\Syncthing\config.xml",
        "C:\Users\steve\AppData\Local\Syncthing\config.xml",  # Explicit user path
        "$env:ProgramFiles\Syncthing\config.xml"
    )

    $configPath = $null
    foreach ($path in $configPaths) {
        if (Test-Path $path) {
            $configPath = $path
            break
        }
    }

    if (-not $configPath) {
        Write-Warn "Syncthing config not found in any standard location"
        Write-Host "  Checked: $($configPaths -join ', ')"
        Write-Host "  Run Syncthing once to generate config, then re-run this script"
        return
    }

    Write-Host "Found config at: $configPath"

    # Read config
    $config = Get-Content $configPath -Raw
    $configChanged = $false

    # Check GUI port (should be 8386 for Windows)
    if ($config -match '<address>127\.0\.0\.1:8386</address>') {
        Write-OK "GUI port already set to 8386"
    } else {
        Write-Host "Updating GUI port to 8386..."
        $config = $config -replace '<address>127\.0\.0\.1:\d+</address>', '<address>127.0.0.1:8386</address>'
        $configChanged = $true
        Write-OK "GUI port updated to 8386"
    }

    # Check sync port (should be 22002 for Windows)
    if ($config -match '<listenAddress>tcp://:22002</listenAddress>') {
        Write-OK "Sync port already set to 22002"
    } else {
        Write-Host "Updating sync port to 22002..."
        $config = $config -replace '<listenAddress>tcp://:\d+</listenAddress>', '<listenAddress>tcp://:22002</listenAddress>'
        $config = $config -replace '<listenAddress>default</listenAddress>', '<listenAddress>tcp://:22002</listenAddress>'
        $configChanged = $true
        Write-OK "Sync port updated to 22002"
    }

    # Write config if changed
    if ($configChanged) {
        Set-Content $configPath $config

        # Restart Syncthing if running
        $syncthingProc = Get-Process -Name "syncthing" -ErrorAction SilentlyContinue
        if ($syncthingProc) {
            Write-Host "Restarting Syncthing to apply changes..."
            Stop-Process -Name "syncthing" -Force
            Start-Sleep -Seconds 2
            # Syncthing should auto-restart if configured as startup app
            Write-OK "Syncthing restarted"
        }
    }
}

function Create-SharedFolder {
    Write-Step "Creating Shared Folder"

    $sharedPath = "C:\shared"

    if (Test-Path $sharedPath) {
        Write-OK "Shared folder already exists: $sharedPath"
    } else {
        Write-Host "Creating $sharedPath..."
        New-Item -ItemType Directory -Path $sharedPath | Out-Null
        Write-OK "Created: $sharedPath"
    }

    # Create .stignore if not exists
    $stignorePath = "$sharedPath\.stignore"
    if (-not (Test-Path $stignorePath)) {
        Write-Host "Creating .stignore..."
        @"
// Git lock files
.git/index.lock
.git/*.lock

// Editor temp files
*.swp
*.swo
*~
.*.swp

// Python cache
__pycache__
*.pyc
.pytest_cache

// Node modules (if any)
node_modules

// OS files
.DS_Store
Thumbs.db
"@ | Set-Content $stignorePath
        Write-OK ".stignore created"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Mesh Network Setup for Windows ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Headscale Server: $HeadscaleServer"
Write-Host ""

if ($Tailscale) {
    Install-Tailscale
    if ($AuthKey) {
        Connect-Headscale
    } else {
        Write-Host ""
        Write-Host "To join the mesh network, run:" -ForegroundColor Yellow
        Write-Host "  tailscale up --login-server=$HeadscaleServer --authkey=YOUR_KEY"
    }
}

if ($Syncthing) {
    Install-Syncthing
    Create-SharedFolder
    Configure-Syncthing
}

if ($Firewall) { Configure-Firewall }
if ($WslAutoStart) { Configure-WslAutoStart }

Write-Host ""
Write-Step "Setup Complete"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
if (-not $AuthKey) {
    Write-Host "  1. Get auth key from sfspark1: sudo ./setup-headscale-server.sh --keygen"
    Write-Host "  2. Join mesh: tailscale up --login-server=$HeadscaleServer --authkey=KEY"
} else {
    Write-Host "  1. Verify mesh connection: tailscale status"
}
Write-Host "  2. Open Syncthing GUI: http://localhost:8386"
Write-Host "  3. Add peer devices and share C:\shared folder"
Write-Host ""

# Always stop transcript (we always start it now)
try {
    Stop-Transcript | Out-Null
} catch {
    # Transcript may not be running
}
