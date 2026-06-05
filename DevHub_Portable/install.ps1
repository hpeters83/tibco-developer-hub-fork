<#
.SYNOPSIS
  DevHub Portable bootstrap (Windows).

.DESCRIPTION
  Downloads the Windows portable bundle, extracts it (once, into the current folder
  as .\devhub-win32-x64\) and starts the TIBCO Developer Hub. Re-running just
  relaunches the extracted bundle.

  One-liner (downloads then runs):
    powershell -ExecutionPolicy Bypass -Command "irm <raw-url>/DevHub_Portable/install.ps1 -OutFile $env:TEMP\devhub-install.ps1; & $env:TEMP\devhub-install.ps1 -Port 8088"

.PARAMETER Port
  Port the hub listens on (default 7007).
.PARAMETER Config
  One or more extra app-config files to layer on top.
.PARAMETER Repo
  GitHub owner/repo (default hpeters83/tibco-developer-hub-fork). Or set $env:DEVHUB_REPO.
.PARAMETER Version
  Release tag or "latest" (default latest). Or set $env:DEVHUB_VERSION.
.PARAMETER Url
  Full URL to devhub-win32-x64.zip (overrides Repo/Version). Or set $env:DEVHUB_URL.
#>
param(
  [int]$Port = 0,
  [string[]]$Config = @(),
  [string]$Repo = $(if ($env:DEVHUB_REPO) { $env:DEVHUB_REPO } else { 'hpeters83/tibco-developer-hub-fork' }),
  [string]$Version = $(if ($env:DEVHUB_VERSION) { $env:DEVHUB_VERSION } else { 'latest' }),
  [string]$Url = $env:DEVHUB_URL
)
$ErrorActionPreference = 'Stop'

$Target = 'win32-x64'
$InstallRoot = if ($env:DEVHUB_DIR) { $env:DEVHUB_DIR } else { (Get-Location).Path }

if (-not $Url) {
  if ($Version -eq 'latest') {
    Write-Host "devhub-install: resolving latest release of $Repo ..."
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $Version = $rel.tag_name
    if (-not $Version) { throw "could not resolve latest release; pass -Version portable-vX.Y.Z" }
  }
  $Url = "https://github.com/$Repo/releases/download/$Version/devhub-$Target.zip"
}

$Dest = $InstallRoot
$Bundle = Join-Path $Dest "devhub-$Target"
$Launcher = Join-Path $Bundle 'devhub.cmd'

if (($env:DEVHUB_FORCE -eq '1') -and (Test-Path $Bundle)) { Remove-Item -Recurse -Force $Bundle }

if (-not (Test-Path $Launcher)) {
  Write-Host "devhub-install: downloading $Url"
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  $tmpZip = Join-Path $env:TEMP ("devhub-" + [System.Guid]::NewGuid().ToString('N') + '.zip')
  Invoke-WebRequest -Uri $Url -OutFile $tmpZip
  Write-Host "devhub-install: extracting to $Bundle"
  if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
  Expand-Archive -Path $tmpZip -DestinationPath $Dest -Force
  Remove-Item -Force $tmpZip
}

if (-not (Test-Path $Launcher)) { throw "bundle launcher not found at $Launcher after extraction." }

# Build pass-through args.
$devhubArgs = @()
if ($Port -gt 0) { $devhubArgs += @('--port', "$Port") }
foreach ($c in $Config) { $devhubArgs += @('--config', $c) }

Write-Host "devhub-install: starting hub from $Bundle"
& $Launcher @devhubArgs
exit $LASTEXITCODE
