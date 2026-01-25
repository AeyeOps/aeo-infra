#Requires -RunAsAdministrator
# OpenSSH Server Setup Script for Windows
# Enables SSH access TO this Windows machine (for WSL or remote Linux access)
#
# SAFETY GUARANTEE:
#   - Idempotent: safe to run multiple times
#   - Only enables built-in Windows features
#   - Does not modify existing SSH configurations
#
# Run from elevated PowerShell:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\setup-openssh-windows.ps1

param(
    [int]$Port = 22,
    [string]$PublicKey = "",
    [string]$PublicKeyFile = "",
    [string]$LogFile = ""
)

# Read key from file if provided
if ($PublicKeyFile -ne "" -and (Test-Path $PublicKeyFile)) {
    $PublicKey = (Get-Content $PublicKeyFile -Raw).Trim()
}

$ErrorActionPreference = "Stop"

# Start transcript if log file specified (for capturing output back to WSL)
if ($LogFile -ne "") {
    Start-Transcript -Path $LogFile -Force | Out-Null
}

Write-Host "=== Windows OpenSSH Server Setup ===" -ForegroundColor Cyan
Write-Host ""

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

# Check current OpenSSH Server status
Write-Host "Checking OpenSSH Server capability..."
$sshCapability = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"

if ($sshCapability.State -eq "Installed") {
    Write-Host "  OpenSSH Server: Already installed" -ForegroundColor DarkGray
} else {
    Write-Host "  Installing OpenSSH Server..." -ForegroundColor Yellow
    Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
    Write-Host "  OpenSSH Server: Installed" -ForegroundColor Green
}

# Configure and start sshd service
Write-Host "Configuring sshd service..."
$sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue

if ($null -eq $sshdService) {
    Write-Host "  ERROR: sshd service not found after installation" -ForegroundColor Red
    exit 1
}

# Set to automatic start
if ($sshdService.StartType -ne "Automatic") {
    Write-Host "  Setting sshd to start automatically..." -ForegroundColor Yellow
    Set-Service -Name sshd -StartupType Automatic
    Write-Host "  Startup type: Automatic" -ForegroundColor Green
} else {
    Write-Host "  Startup type: Already set to Automatic" -ForegroundColor DarkGray
}

# Start the service if not running
if ($sshdService.Status -ne "Running") {
    Write-Host "  Starting sshd service..." -ForegroundColor Yellow
    Start-Service sshd
    Write-Host "  Service: Started" -ForegroundColor Green
} else {
    Write-Host "  Service: Already running" -ForegroundColor DarkGray
}

# Configure firewall rule
Write-Host "Checking firewall rule..."
$firewallRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue

if ($null -eq $firewallRule) {
    Write-Host "  Creating firewall rule..." -ForegroundColor Yellow
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port -Profile Any | Out-Null
    Write-Host "  Firewall rule: Created" -ForegroundColor Green
} else {
    if (-not $firewallRule.Enabled) {
        Write-Host "  Enabling firewall rule..." -ForegroundColor Yellow
        Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP"
        Write-Host "  Firewall rule: Enabled" -ForegroundColor Green
    } else {
        Write-Host "  Firewall rule: Already exists and enabled" -ForegroundColor DarkGray
    }
}

# Ensure ssh-agent is running (optional but helpful)
Write-Host "Checking ssh-agent service..."
$sshAgentService = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue

if ($null -ne $sshAgentService) {
    if ($sshAgentService.StartType -eq "Disabled") {
        Write-Host "  Enabling ssh-agent..." -ForegroundColor Yellow
        Set-Service -Name ssh-agent -StartupType Manual
    }
    Write-Host "  ssh-agent: Configured" -ForegroundColor DarkGray
}

# Set up SSH key authentication
Write-Host "Configuring SSH key authentication..."

# Determine if current user is an administrator
$userIsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$adminGroups = (whoami /groups) -match 'BUILTIN\\Administrators'

# Admin users need keys in a different location
if ($adminGroups) {
    $authKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    Write-Host "  User is in Administrators group" -ForegroundColor DarkGray
    Write-Host "  Using: $authKeysFile" -ForegroundColor DarkGray
} else {
    $sshDir = "$env:USERPROFILE\.ssh"
    $authKeysFile = "$sshDir\authorized_keys"
    Write-Host "  Using: $authKeysFile" -ForegroundColor DarkGray

    # Ensure user .ssh directory exists
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Write-Host "  Created $sshDir" -ForegroundColor Green
    }
}

# Add public key if provided
if ($PublicKey -ne "") {
    # Extract key fingerprint for idempotency check (the unique part of the key)
    $keyParts = $PublicKey -split '\s+'
    if ($keyParts.Count -ge 2) {
        $keyFingerprint = $keyParts[1]  # The base64-encoded key data
    } else {
        $keyFingerprint = $PublicKey
    }

    $keyExists = $false
    if (Test-Path $authKeysFile) {
        $existing = Get-Content $authKeysFile -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing.Contains($keyFingerprint)) {
            $keyExists = $true
        }
    }

    if ($keyExists) {
        Write-Host "  SSH key: Already authorized (skipped)" -ForegroundColor DarkGray
    } else {
        # Create file or append key
        if (-not (Test-Path $authKeysFile)) {
            Set-Content -Path $authKeysFile -Value $PublicKey
            Write-Host "  SSH key: Added (new file)" -ForegroundColor Green
        } else {
            Add-Content -Path $authKeysFile -Value $PublicKey
            Write-Host "  SSH key: Added" -ForegroundColor Green
        }

        # Set correct permissions for admin keys file
        if ($adminGroups) {
            icacls $authKeysFile /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
            Write-Host "  Permissions: Set (Administrators + SYSTEM only)" -ForegroundColor Green
        }
    }
} else {
    # No key provided, just report status
    if (Test-Path $authKeysFile) {
        $keyCount = (Get-Content $authKeysFile | Where-Object { $_ -match '\S' }).Count
        Write-Host "  authorized_keys: $keyCount key(s) configured" -ForegroundColor DarkGray
    } else {
        Write-Host "  authorized_keys: Not yet created" -ForegroundColor Yellow
        Write-Host "  Provide -PublicKey parameter or use ssh-copy-id" -ForegroundColor Yellow
    }
}

# Verification
Write-Host ""
Write-Host "=== Verification ===" -ForegroundColor Cyan

# Service status
$sshdStatus = (Get-Service sshd).Status
Write-Host "  sshd service: $sshdStatus" -ForegroundColor $(if ($sshdStatus -eq "Running") { "Green" } else { "Red" })

# Listening port
$listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listening) {
    Write-Host "  Listening on port ${Port}: Yes" -ForegroundColor Green
} else {
    Write-Host "  Listening on port ${Port}: No" -ForegroundColor Red
}

# Get local IP
$localIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notmatch "^169\." } | Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "SSH server is now running on this Windows machine." -ForegroundColor White
Write-Host ""
Write-Host "To connect from WSL or Linux:" -ForegroundColor White
Write-Host "  ssh $env:USERNAME@$localIP" -ForegroundColor Green
Write-Host "  ssh $env:USERNAME@$(hostname)" -ForegroundColor Green
Write-Host ""
Write-Host "To set up key-based auth (from WSL):" -ForegroundColor White
Write-Host "  ssh-copy-id $env:USERNAME@$localIP" -ForegroundColor Cyan
Write-Host ""

# Stop transcript if we started one
if ($LogFile -ne "") {
    Stop-Transcript | Out-Null
}
