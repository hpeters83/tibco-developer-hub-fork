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
.PARAMETER Variant
  bundled | classic (default bundled). "bundled" is the single index.js + minimal
  node_modules build (~3k files, extracts fast); "classic" is the full folder build.
  Or set $env:DEVHUB_VARIANT.
.PARAMETER Url
  Full URL to devhub[-bundled]-win32-x64.zip (overrides Repo/Version/Variant). Or set $env:DEVHUB_URL.
#>
param(
  [int]$Port = 0,
  [string[]]$Config = @(),
  [string]$Repo = $(if ($env:DEVHUB_REPO) { $env:DEVHUB_REPO } else { 'hpeters83/tibco-developer-hub-fork' }),
  [string]$Version = $(if ($env:DEVHUB_VERSION) { $env:DEVHUB_VERSION } else { 'latest' }),
  [ValidateSet('bundled','classic')]
  [string]$Variant = $(if ($env:DEVHUB_VARIANT) { $env:DEVHUB_VARIANT } else { 'bundled' }),
  [string]$Url = $env:DEVHUB_URL
)
$ErrorActionPreference = 'Stop'

$Target = 'win32-x64'
$Name = if ($Variant -eq 'bundled') { "devhub-bundled-$Target" } else { "devhub-$Target" }
$InstallRoot = if ($env:DEVHUB_DIR) { $env:DEVHUB_DIR } else { (Get-Location).Path }

if (-not $Url) {
  if ($Version -eq 'latest') {
    Write-Host "devhub-install: resolving latest release of $Repo ..."
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
    $Version = $rel.tag_name
    if (-not $Version) { throw "could not resolve latest release; pass -Version portable-vX.Y.Z" }
  }
  $Url = "https://github.com/$Repo/releases/download/$Version/$Name.zip"
}

$Dest = $InstallRoot
$Bundle = Join-Path $Dest $Name
$Launcher = Join-Path $Bundle 'devhub.cmd'

if (($env:DEVHUB_FORCE -eq '1') -and (Test-Path $Bundle)) { Remove-Item -Recurse -Force $Bundle }

if (-not (Test-Path $Launcher)) {
  Write-Host "devhub-install: downloading $Url"
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  $tmpZip = Join-Path $env:TEMP ("devhub-" + [System.Guid]::NewGuid().ToString('N') + '.zip')
  Invoke-WebRequest -Uri $Url -OutFile $tmpZip
  Write-Host "devhub-install: extracting to $Bundle"
  if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
  # Extraction strategy depends on the variant:
  #   bundled -> .NET ZipFile. The single index.js entry is ~80 MB deflated, which trips
  #     the bsdtar/libarchive build shipped with Windows ("ZIP decompression failed (-5)").
  #     .NET inflates large entries reliably, and the bundled layout is shallow + few files
  #     so it has none of the MAX_PATH / speed problems that plague the classic tree.
  #   classic -> bsdtar (tar.exe). Far faster on the deep node_modules tree and, unlike
  #     .NET/Expand-Archive, handles the long paths / symlinks deep under node\node_modules
  #     (e.g. the "Cannot find path ...\node\node_modules\corepack" rollback error).
  if ($Variant -eq 'bundled') {
    # ZipFile is built-in on PowerShell 7 (.NET); on Windows PowerShell 5.1 it needs
    # the FileSystem assembly loaded first. Tolerate either.
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch {}
    [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $Dest)
  } else {
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
      & $tar.Source -xf $tmpZip -C $Dest
      if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit $LASTEXITCODE)" }
    } else {
      Write-Warning 'devhub-install: tar.exe not found; falling back to Expand-Archive (slower).'
      Expand-Archive -Path $tmpZip -DestinationPath $Dest -Force
    }
  }
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
