<#
.SYNOPSIS
  Build the BUNDLED "DevHub Portable" for Windows x64.

.DESCRIPTION
  Uses esbuild to collapse the backend into a single index.js and ships only a minimal
  sidecar node_modules (native modules + the few packages that load on-disk assets).
  Result: ~3k files, so the zip extracts in seconds.

  Output: DevHub_Portable\dist\devhub-bundled-win32-x64\ and a matching .zip.

  Requires: Node (same major as embedded), Yarn (corepack), MSVC C++ Build Tools +
  Python 3 on PATH (so node-gyp can compile isolated-vm / better-sqlite3).

.PARAMETER SkipInstall  Skip "yarn install --immutable".
.PARAMETER NoZip        Do not produce the .zip.
.PARAMETER KeepNode     Keep the full Node runtime (default strips it to node.exe).
.PARAMETER TechDocs     ALSO build the self-contained devhub-bundled-techdocs-win32-x64 zip
                        (embeds a standalone Python + mkdocs so TechDocs needs no host
                        Python/network; larger zip).
#>
param(
  [switch]$SkipInstall,
  [switch]$NoZip,
  [switch]$KeepNode,
  [switch]$TechDocs
)
$PbsPythonSeries = if ($env:PBS_PYTHON_SERIES) { $env:PBS_PYTHON_SERIES } else { '3.12' }
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is 10-50x slower while its progress bar is on (Windows PowerShell
# re-renders it constantly and buffers the whole response in memory), which makes the
# Node download crawl. Disable it for the whole script.
$ProgressPreference = 'SilentlyContinue'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Split-Path -Parent $ScriptDir
$Root        = Split-Path -Parent $PortableDir
$Out         = Join-Path $PortableDir 'dist'

$Os     = 'win32'
$Arch   = 'x64'
$Target = "$Os-$Arch"
$Bundle = Join-Path $Out "devhub-bundled-$Target"
$NodeVersion = (& node -v).Trim()

Write-Host "==> Building DevHub Portable (bundled) for $Target (Node $NodeVersion)"

# --- 1. install + build the frontend (root base path) ----------------------
Push-Location $Root
try {
  if (-not $SkipInstall) {
    Write-Host '==> yarn install --immutable'
    yarn install --immutable
  }
  $env:APP_CONFIG_app_baseUrl = 'http://localhost:7007'
  $env:APP_CONFIG_backend_baseUrl = 'http://localhost:7007'
  Write-Host '==> yarn workspace app build (frontend static assets)'
  yarn workspace app build
} finally {
  Pop-Location
}

# --- 2. esbuild the backend into a single index.js -------------------------
Write-Host '==> esbuild backend -> index.js'
if (Test-Path $Bundle) { Remove-Item -Recurse -Force $Bundle }
New-Item -ItemType Directory -Path $Bundle | Out-Null
$env:DEVHUB_BUNDLE_OUT = $Bundle
node (Join-Path $ScriptDir 'esbuild-backend.mjs')
if (-not (Test-Path (Join-Path $Bundle 'index.js'))) { throw 'esbuild did not produce index.js' }

# --- 3. discover the minimal sidecar by tracing a real boot ----------------
Write-Host '==> Tracing runtime module usage (booting the bundle)'
$PkgList = Join-Path ([System.IO.Path]::GetTempPath()) ("devhub-pkgs-" + [System.Guid]::NewGuid().ToString('N') + '.txt')
$DataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("devhub-trace-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $DataDir | Out-Null
$env:DEVHUB_TRACE_BUNDLE = (Join-Path $Bundle 'index.js')
$env:DEVHUB_TRACE_OUT    = $PkgList
$env:DEVHUB_TRACE_EXIT_MS = '20000'
$env:DEVHUB_PORT = '7071'
$env:DEVHUB_DATA_DIR = $DataDir
$env:DOC_URL = 'https://example.com'
$env:NODE_OPTIONS = '--no-node-snapshot'
# Self-exits after DEVHUB_TRACE_EXIT_MS. Booting the bundle writes warnings to stderr
# (e.g. the punycode DeprecationWarning); with $ErrorActionPreference='Stop' PowerShell
# turns native-command stderr into a terminating NativeCommandError, so relax it just for
# this call. The *> redirect captures all output to the log, and success is judged by
# whether the package list was written (checked below), not by the exit/stderr.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& node (Join-Path $ScriptDir 'trace-requires.cjs') --config (Join-Path $PortableDir 'config\app-config.portable.yaml') *> (Join-Path $DataDir 'trace.log')
$ErrorActionPreference = $prevEAP
if (-not (Test-Path $PkgList) -or (Get-Item $PkgList).Length -eq 0) {
  Write-Host (Get-Content (Join-Path $DataDir 'trace.log') -Tail 30 -ErrorAction SilentlyContinue)
  throw 'trace produced no package list'
}
Write-Host ("    {0} packages traced" -f (Get-Content $PkgList | Where-Object { $_ }).Count)

# --- 4. build the minimal sidecar node_modules -----------------------------
Write-Host '==> Building minimal sidecar node_modules'
node (Join-Path $ScriptDir 'build-sidecar.cjs') $Root (Join-Path $Bundle 'node_modules') $PkgList $Target
foreach ($m in @('isolated-vm','better-sqlite3')) {
  if (-not (Test-Path (Join-Path $Bundle "node_modules\$m"))) { Write-Warning "$m missing from sidecar" }
}
Remove-Item -Recurse -Force $DataDir -ErrorAction SilentlyContinue
Remove-Item -Force $PkgList -ErrorAction SilentlyContinue

# --- 5. embed (and strip) the Node runtime ---------------------------------
Write-Host "==> Downloading Node $NodeVersion for $Target"
$NodePkg = "node-$NodeVersion-win-$Arch"   # nodejs.org uses the "win" token
$TmpNode = Join-Path ([System.IO.Path]::GetTempPath()) ("devhub-node-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TmpNode | Out-Null
$NodeZip = Join-Path $TmpNode 'node.zip'
$NodeUrl = "https://nodejs.org/dist/$NodeVersion/$NodePkg.zip"
# Prefer curl.exe (ships with Windows 10 1803+) for full-speed streaming; fall back to IWR.
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) {
  & $curl.Source -fSL --retry 3 $NodeUrl -o $NodeZip
  if ($LASTEXITCODE -ne 0) { throw "Node download failed (curl exit $LASTEXITCODE)" }
} else {
  Invoke-WebRequest -Uri $NodeUrl -OutFile $NodeZip
}
Expand-Archive -Path $NodeZip -DestinationPath $TmpNode
if (Test-Path (Join-Path $Bundle 'node')) { Remove-Item -Recurse -Force (Join-Path $Bundle 'node') }
Move-Item (Join-Path $TmpNode $NodePkg) (Join-Path $Bundle 'node')
Remove-Item -Recurse -Force $TmpNode
if (-not $KeepNode) {
  Write-Host '==> Stripping Node runtime to node.exe (drops npm/corepack)'
  # The backend never shells out to npm; only node.exe is needed at runtime.
  Get-ChildItem (Join-Path $Bundle 'node') -Force |
    Where-Object { $_.Name -ne 'node.exe' } |
    Remove-Item -Recurse -Force
}
if (-not (Test-Path (Join-Path $Bundle 'node\node.exe'))) { throw 'embedded node.exe missing' }

# --- 6. config, launcher, readme -------------------------------------------
Write-Host '==> Adding config, launcher and README'
Copy-Item (Join-Path $PortableDir 'config\app-config.portable.yaml') $Bundle
Copy-Item (Join-Path $PortableDir 'launchers\devhub.cmd') $Bundle
Copy-Item (Join-Path $PortableDir 'launchers\find-free-port.cjs') $Bundle
New-Item -ItemType Directory -Path (Join-Path $Bundle 'data') | Out-Null
# Version stamp shown on launch. For release downloads the installer overwrites this
# with the release tag; a directly-run local build keeps this build marker.
Set-Content -Path (Join-Path $Bundle '.devhub-release') `
  -Value ("local build " + (Get-Date -Format 'yyyy-MM-ddTHH:mmZ')) -NoNewline

@"
TIBCO Developer Hub - Portable, bundled ($Target)

Run:
  devhub.cmd                      Start on http://localhost:7007
  devhub.cmd --port 8088          Start on a custom port
  devhub.cmd --config .\my.yaml   Load extra app-config (repeatable)

The backend is a single index.js and node_modules\ contains only the native modules
and on-disk assets it loads at runtime, so the folder has few files and extracts fast.

Data is stored under .\data and persists across restarts. No Docker/Postgres.
Built with embedded Node $NodeVersion.
"@ | Set-Content -Path (Join-Path $Bundle 'README.txt') -Encoding UTF8

# --- 7. zip ----------------------------------------------------------------
if (-not $NoZip) {
  Write-Host '==> Zipping'
  $Zip = Join-Path $Out "devhub-bundled-$Target.zip"
  if (Test-Path $Zip) { Remove-Item -Force $Zip }
  Push-Location $Out
  try {
    & tar.exe -c -f $Zip --format zip "devhub-bundled-$Target"
    if ($LASTEXITCODE -ne 0) { throw "tar zip creation failed (exit $LASTEXITCODE)" }
  } finally { Pop-Location }
  Write-Host "==> Wrote $Zip"
}

Write-Host "==> Done: $Bundle"

# --- 8. techdocs variant (optional) ----------------------------------------
# Self-contained build: a copy of the lean bundle plus a RELOCATABLE standalone
# Python (from astral-sh/python-build-standalone) with mkdocs-techdocs-core
# pre-installed under .\python, and a .\python-bin\mkdocs.cmd wrapper the launcher
# prefers. TechDocs then renders with no host Python and no network. Larger zip.
if ($TechDocs) {
  Write-Host "==> Building self-contained TechDocs variant (devhub-bundled-techdocs-$Target)"
  $TdBundle = Join-Path $Out "devhub-bundled-techdocs-$Target"
  if (Test-Path $TdBundle) { Remove-Item -Recurse -Force $TdBundle }
  Copy-Item -Recurse -Force $Bundle $TdBundle

  $triple = 'x86_64-pc-windows-msvc'
  Write-Host "==> Resolving standalone Python ($PbsPythonSeries, $triple)"
  $hdr = @{ 'User-Agent' = 'devhub-build' }
  if ($env:GITHUB_TOKEN) { $hdr['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
  $rel = Invoke-RestMethod -Headers $hdr `
    'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest'
  $seriesRe = [regex]::Escape($PbsPythonSeries)
  # Prefer 'install_only_stripped' (debug symbols removed, much smaller); fall back to plain.
  $asset = $rel.assets |
    Where-Object { $_.name -match "cpython-$seriesRe\.\d.*-$triple-install_only_stripped\.tar\.gz$" } |
    Select-Object -First 1
  if (-not $asset) {
    $asset = $rel.assets |
      Where-Object { $_.name -match "cpython-$seriesRe\.\d.*-$triple-install_only\.tar\.gz$" } |
      Select-Object -First 1
  }
  if (-not $asset) { throw "could not resolve a standalone Python for $triple (series $PbsPythonSeries)" }

  Write-Host "==> Downloading $($asset.name)"
  $TmpPy = Join-Path ([System.IO.Path]::GetTempPath()) ("devhub-py-" + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $TmpPy | Out-Null
  $PyTar = Join-Path $TmpPy 'python.tar.gz'
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    & $curl.Source -fSL --retry 3 $asset.browser_download_url -o $PyTar
    if ($LASTEXITCODE -ne 0) { throw "Python download failed (curl exit $LASTEXITCODE)" }
  } else {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $PyTar
  }
  & tar.exe -x -z -f $PyTar -C $TmpPy   # extracts to $TmpPy\python
  if ($LASTEXITCODE -ne 0) { throw "Python extract failed (tar exit $LASTEXITCODE)" }
  if (Test-Path (Join-Path $TdBundle 'python')) { Remove-Item -Recurse -Force (Join-Path $TdBundle 'python') }
  Move-Item (Join-Path $TmpPy 'python') (Join-Path $TdBundle 'python')
  Remove-Item -Recurse -Force $TmpPy

  Write-Host '==> Installing mkdocs-techdocs-core into embedded Python'
  $PyExe = Join-Path $TdBundle 'python\python.exe'
  & $PyExe -m ensurepip --upgrade 2>$null
  & $PyExe -m pip install --quiet --disable-pip-version-check --upgrade pip mkdocs-techdocs-core
  if ($LASTEXITCODE -ne 0) { throw "pip install mkdocs-techdocs-core failed (exit $LASTEXITCODE)" }

  # Path-independent wrapper: Backstage spawns the literal `mkdocs` command.
  New-Item -ItemType Directory -Path (Join-Path $TdBundle 'python-bin') | Out-Null
  @'
@echo off
"%~dp0..\python\python.exe" -m mkdocs %*
'@ | Set-Content -Path (Join-Path $TdBundle 'python-bin\mkdocs.cmd') -Encoding ASCII

  Add-Content -Path (Join-Path $TdBundle 'README.txt') -Value @"

This is the self-contained TechDocs build: it embeds a standalone Python runtime
with mkdocs (under .\python) so generating documentation works with no host Python
and no network access. It is larger than the standard bundle for that reason.
"@

  if (-not $NoZip) {
    Write-Host '==> Zipping techdocs variant'
    $TdZip = Join-Path $Out "devhub-bundled-techdocs-$Target.zip"
    if (Test-Path $TdZip) { Remove-Item -Force $TdZip }
    Push-Location $Out
    try {
      & tar.exe -c -f $TdZip --format zip "devhub-bundled-techdocs-$Target"
      if ($LASTEXITCODE -ne 0) { throw "tar zip creation failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    Write-Host "==> Wrote $TdZip"
  }
  Write-Host "==> Done: $TdBundle"
}
