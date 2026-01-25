#Requires -RunAsAdministrator
# SSHFS Windows Setup Script
# Installs WinFsp + SSHFS-Win to enable UNC access to sfspark1:/opt/shared
#
# After setup, access via: \\sshfs\steve@sfspark1.local\opt\shared
#
# SAFETY GUARANTEES:
#   - This script only installs software and verifies connectivity
#   - It does NOT create drive mappings or modify existing mounts
#   - It will NEVER copy, create, or modify SSH keys
#
# Prerequisites:
#   - SSH key pair exists (~/.ssh/id_ed25519 or id_rsa)
#   - Key is authorized on sfspark1 (ssh-copy-id from WSL)
#
# Run from elevated PowerShell:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\setup-sshfs-windows.ps1

param(
    [string]$Server = "sfspark1.local",
    [string]$User = "steve",
    [string]$RemotePath = "/opt/shared"
)

$ErrorActionPreference = "Stop"

Write-Host "=== SSHFS Windows Setup ===" -ForegroundColor Cyan
Write-Host ""

# Check winget available
Write-Host "Checking winget..."
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: winget not found. Install App Installer from Microsoft Store." -ForegroundColor Red
    exit 1
}
Write-Host "  winget: Available" -ForegroundColor DarkGray
Write-Host ""

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

# Check WinFsp
Write-Host "Checking WinFsp..."
$winfspPath = "C:\Program Files (x86)\WinFsp"
if (-not (Test-Path $winfspPath)) {
    Write-Host "  Installing WinFsp via winget..." -ForegroundColor Yellow
    winget install WinFsp.WinFsp --accept-package-agreements --accept-source-agreements --silent | Out-Null
    Write-Host "  WinFsp: Installed" -ForegroundColor Green
} else {
    Write-Host "  WinFsp: Already installed" -ForegroundColor DarkGray
}

# Check SSHFS-Win
Write-Host "Checking SSHFS-Win..."
$sshfsPath = "C:\Program Files\SSHFS-Win"
if (-not (Test-Path $sshfsPath)) {
    Write-Host "  Installing SSHFS-Win via winget..." -ForegroundColor Yellow
    winget install SSHFS-Win.SSHFS-Win --accept-package-agreements --accept-source-agreements --silent | Out-Null
    Write-Host "  SSHFS-Win: Installed" -ForegroundColor Green
} else {
    Write-Host "  SSHFS-Win: Already installed" -ForegroundColor DarkGray
}

# Check for sfspark1-specific SSH key (created by setup-sshfs-windows.sh)
Write-Host "Checking SSH key..."
$sfspark1Key = "$env:USERPROFILE\.ssh\id_ed25519_sfspark1"

if (Test-Path $sfspark1Key) {
    Write-Host "  SSH key: Found at $sfspark1Key" -ForegroundColor DarkGray
} else {
    Write-Host "  SSH key for sfspark1 not found" -ForegroundColor Yellow
    Write-Host "  Run setup-sshfs-windows.sh from WSL first" -ForegroundColor White
    exit 2
}

# Test SSH connectivity
Write-Host "Testing SSH connectivity to $Server..."
$sshOk = $false
try {
    $sshTest = & ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$User@$Server" "echo OK" 2>&1
    if ($sshTest -match "OK") {
        Write-Host "  SSH connection: OK" -ForegroundColor Green
        $sshOk = $true
    } else {
        Write-Host "  WARNING: SSH connection failed" -ForegroundColor Yellow
        Write-Host "  Output: $sshTest" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  WARNING: SSH test error: $_" -ForegroundColor Yellow
}

if (-not $sshOk) {
    Write-Host ""
    Write-Host "  SSH connectivity issue detected" -ForegroundColor Yellow
    Write-Host "  Run setup-sshfs-windows.sh from WSL to configure SSH" -ForegroundColor White
    exit 2
}

# Build the UNC path
$uncPath = "\\sshfs\$User@$Server$RemotePath"

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Access the share via UNC path:" -ForegroundColor White
Write-Host ""
Write-Host "  $uncPath" -ForegroundColor Green
Write-Host ""
Write-Host "You can:" -ForegroundColor White
Write-Host "  - Paste this path into File Explorer's address bar"
Write-Host "  - Use in Open/Save dialogs"
Write-Host "  - Map to a drive letter manually if desired: net use S: $uncPath"
Write-Host ""

# Verify access
Write-Host "Verifying access to $uncPath ..."
Write-Host ""

$maxAttempts = 3
$attempt = 0
$accessible = $false

while ($attempt -lt $maxAttempts -and -not $accessible) {
    $attempt++
    try {
        # Test-Path can be slow on first SSHFS access as it establishes the SSH connection
        $testResult = Test-Path $uncPath -ErrorAction Stop
        if ($testResult) {
            $accessible = $true
        } else {
            Write-Host "  Attempt $attempt/$maxAttempts - path not accessible yet..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        }
    } catch {
        Write-Host "  Attempt $attempt/$maxAttempts - error: $($_.Exception.Message)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
}

if ($accessible) {
    Write-Host "  Access VERIFIED - share is reachable" -ForegroundColor Green
    Write-Host ""
    Write-Host "Contents of ${uncPath}:"
    try {
        $items = Get-ChildItem $uncPath -ErrorAction Stop | Select-Object -First 10
        $items | Format-Table Name, @{L='Size';E={if($_.PSIsContainer){'<DIR>'}else{$_.Length}}}, LastWriteTime
        Write-Host "  ($(@(Get-ChildItem $uncPath -ErrorAction SilentlyContinue).Count) total items)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  (Could not list contents: $_)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  WARNING: Could not verify access after $maxAttempts attempts" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  This may be due to:" -ForegroundColor White
    Write-Host "    - SSHFS-Win not fully initialized (try rebooting)" -ForegroundColor White
    Write-Host "    - SSH config not set up (run setup-sshfs-windows.sh from WSL)" -ForegroundColor White
    Write-Host "    - Network/firewall issues" -ForegroundColor White
    Write-Host ""
    Write-Host "  Try accessing manually in Explorer:" -ForegroundColor White
    Write-Host "    $uncPath" -ForegroundColor Cyan
    exit 2
}
