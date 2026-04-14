param(
  [Parameter(Mandatory = $true)]
  [string]$HeadscaleUrl,

  [Parameter(Mandatory = $true)]
  [string]$AuthKey,

  [string]$Hostname
)

$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path $tailscale)) {
  throw "tailscale.exe not found at $tailscale"
}

$args = @(
  'up',
  '--login-server', $HeadscaleUrl,
  '--authkey', $AuthKey,
  '--accept-dns=true'
)

if ($Hostname) {
  $args += @('--hostname', $Hostname)
}

& $tailscale @args
