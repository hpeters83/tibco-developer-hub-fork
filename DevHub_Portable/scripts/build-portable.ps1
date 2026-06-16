<#
.SYNOPSIS
  Build a self-contained "DevHub Portable" bundle for Windows x64.

.DESCRIPTION
  Produces DevHub_Portable\dist\devhub-win32-x64\ (a runnable folder) and a matching
  .zip. Native modules (isolated-vm, better-sqlite3) are compiled for the host, so
  this only builds Windows; the other targets come from the CI matrix.

  Requires: Node (same major as will be embedded), Yarn 4.4.1 (corepack), and MSVC
  C++ Build Tools + Python 3 on PATH (so node-gyp can compile isolated-vm).

.PARAMETER SkipInstall
  Skip "yarn install --immutable".
.PARAMETER NoZip
  Do not produce the .zip.
#>
param(
  [switch]$SkipInstall,
  [switch]$NoZip
)
$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Split-Path -Parent $ScriptDir
$Root        = Split-Path -Parent $PortableDir
$Out         = Join-Path $PortableDir 'dist'

$Os     = 'win32'
$Arch   = 'x64'
$Target = "$Os-$Arch"
$Bundle = Join-Path $Out "devhub-$Target"

# Embed the same Node version that compiles the native modules (ABI match).
$NodeVersion = (& node -v).Trim()   # e.g. v24.15.0

Write-Host "==> Building DevHub Portable for $Target (Node $NodeVersion)"

# --- 1. build the backend bundle (embeds the built frontend) ---------------
Push-Location $Root
try {
  if (-not $SkipInstall) {
    Write-Host '==> yarn install --immutable'
    yarn install --immutable
  }
  Write-Host '==> yarn workspace backend build'
  # Build the frontend with a ROOT base path (no /tibco/hub) — single-process portable
  # has no ingress to strip the prefix, so app + static + /api must all live at root.
  # Backstage bakes the frontend public path from app.baseUrl at build time.
  $env:APP_CONFIG_app_baseUrl = 'http://localhost:7007'
  $env:APP_CONFIG_backend_baseUrl = 'http://localhost:7007'
  yarn workspace backend build
} finally {
  Pop-Location
}

$BundleTgz   = Join-Path $Root 'packages\backend\dist\bundle.tar.gz'
$SkeletonTgz = Join-Path $Root 'packages\backend\dist\skeleton.tar.gz'
if (-not (Test-Path $BundleTgz))   { throw "missing $BundleTgz" }
if (-not (Test-Path $SkeletonTgz)) { throw "missing $SkeletonTgz" }

# --- 2. assemble bundle root ------------------------------------------------
Write-Host "==> Assembling $Bundle"
if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
New-Item -ItemType Directory -Path $Bundle | Out-Null
tar xzf $BundleTgz -C $Bundle    # bsdtar ships with Windows 10+
if (-not (Test-Path (Join-Path $Bundle 'packages\backend'))) { throw 'bundle missing packages\backend' }

# --- 3. production node_modules (compiles native modules) -------------------
Write-Host '==> Installing production dependencies (compiles isolated-vm / better-sqlite3)'
$Prod = Join-Path ([System.IO.Path]::GetTempPath()) ("devhub-prod-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Prod | Out-Null
try {
  tar xzf $SkeletonTgz -C $Prod
  Copy-Item (Join-Path $Root 'package.json')  $Prod
  Copy-Item (Join-Path $Root 'yarn.lock')     $Prod
  Copy-Item (Join-Path $Root '.yarnrc.yml')   $Prod
  if (Test-Path (Join-Path $Root 'backstage.json')) { Copy-Item (Join-Path $Root 'backstage.json') $Prod }
  New-Item -ItemType Directory -Path (Join-Path $Prod '.yarn') | Out-Null
  Copy-Item -Recurse (Join-Path $Root '.yarn\releases') (Join-Path $Prod '.yarn\releases')
  if (Test-Path (Join-Path $Root '.yarn\patches')) { Copy-Item -Recurse (Join-Path $Root '.yarn\patches') (Join-Path $Prod '.yarn\patches') }
  if (Test-Path (Join-Path $Root '.yarn\plugins')) { Copy-Item -Recurse (Join-Path $Root '.yarn\plugins') (Join-Path $Prod '.yarn\plugins') }

  Push-Location $Prod
  try { yarn workspaces focus --all --production } finally { Pop-Location }

  Copy-Item -Recurse (Join-Path $Prod 'node_modules') (Join-Path $Bundle 'node_modules')
} finally {
  Remove-Item -Recurse -Force $Prod -ErrorAction SilentlyContinue
}

foreach ($m in @('isolated-vm','better-sqlite3')) {
  if (-not (Test-Path (Join-Path $Bundle "node_modules\$m"))) { Write-Warning "$m not found in node_modules" }
}

# The in-repo workspace packages (app, @internal/*) are linked into node_modules. On
# Windows yarn creates absolute junctions that break once the bundle is moved/zipped.
# Replace them with real copies sourced from the bundle's own plugins/packages so the
# bundle is fully self-contained.
Write-Host '==> Materializing workspace packages into node_modules (self-contained)'
$wsDirs = @()
$wsDirs += Get-ChildItem -Directory (Join-Path $Bundle 'plugins')  -ErrorAction SilentlyContinue
$wsDirs += Get-ChildItem -Directory (Join-Path $Bundle 'packages') -ErrorAction SilentlyContinue
foreach ($d in $wsDirs) {
  $pj = Join-Path $d.FullName 'package.json'
  if (-not (Test-Path $pj)) { continue }
  $pkgName = (Get-Content $pj -Raw | ConvertFrom-Json).name
  if (-not $pkgName) { continue }
  $dest = Join-Path (Join-Path $Bundle 'node_modules') ($pkgName -replace '/', '\')
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  $parent = Split-Path $dest
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
  Copy-Item -Recurse -Force $d.FullName $dest
}

# --- 4. embed the Node runtime ----------------------------------------------
Write-Host "==> Downloading Node $NodeVersion for $Target"
# nodejs.org uses the "win" token (not "win32") in its archive names.
$NodePkg = "node-$NodeVersion-win-$Arch"
$NodeUrl = "https://nodejs.org/dist/$NodeVersion/$NodePkg.zip"
$TmpNode = Join-Path ([System.IO.Path]::GetTempPath()) ("devhub-node-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpNode | Out-Null
$NodeZip = Join-Path $TmpNode 'node.zip'
Invoke-WebRequest -Uri $NodeUrl -OutFile $NodeZip
Expand-Archive -Path $NodeZip -DestinationPath $TmpNode
if (Test-Path (Join-Path $Bundle 'node')) { Remove-Item -Recurse -Force (Join-Path $Bundle 'node') }
Move-Item (Join-Path $TmpNode $NodePkg) (Join-Path $Bundle 'node')
Remove-Item -Recurse -Force $TmpNode
if (-not (Test-Path (Join-Path $Bundle 'node\node.exe'))) { throw 'embedded node.exe missing' }

# --- 5. config, launcher, readme --------------------------------------------
Write-Host '==> Adding config, launcher and README'
Copy-Item (Join-Path $PortableDir 'config\app-config.portable.yaml') $Bundle
Copy-Item (Join-Path $PortableDir 'launchers\devhub.cmd') $Bundle
Copy-Item (Join-Path $PortableDir 'launchers\find-free-port.cjs') $Bundle
New-Item -ItemType Directory -Path (Join-Path $Bundle 'data') | Out-Null

@"
TIBCO Developer Hub - Portable ($Target)

Run:
  devhub.cmd                      Start on http://localhost:7007
  devhub.cmd --port 8088          Start on a custom port
  devhub.cmd --config .\my.yaml   Load extra app-config (repeatable)

Data (SQLite + scaffolder workspace) is stored under .\data and persists across
restarts. Delete .\data to reset. No Docker or Postgres required.

Built with embedded Node $NodeVersion.
"@ | Set-Content -Path (Join-Path $Bundle 'README.txt') -Encoding UTF8

# --- 6. zip ------------------------------------------------------------------
if (-not $NoZip) {
  Write-Host '==> Zipping'
  $Zip = Join-Path $Out "devhub-$Target.zip"
  if (Test-Path $Zip) { Remove-Item -Force $Zip }
  # Build the zip with bsdtar, not Compress-Archive: Compress-Archive is slow and shares
  # the same Windows MAX_PATH fragility that can silently drop deep node_modules entries,
  # and the resulting archive is what install.ps1 must extract.
  Push-Location $Out
  try {
    & tar.exe -c -f $Zip --format zip "devhub-$Target"
    if ($LASTEXITCODE -ne 0) { throw "tar zip creation failed (exit $LASTEXITCODE)" }
  } finally {
    Pop-Location
  }
  Write-Host "==> Wrote $Zip"
}

Write-Host "==> Done: $Bundle"
