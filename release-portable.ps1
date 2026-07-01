<#
.SYNOPSIS
  Build the Windows DevHub Portable zip(s) and publish/attach them to a GitHub release.

.DESCRIPTION
  The Windows counterpart to release-portable.sh. It:
    1. builds the win32-x64 bundle zips (lean + self-contained TechDocs) via build-bundled.ps1
    2. optionally tags the commit (portable-v*)
    3. creates the GitHub release, OR — if it already exists — uploads the zips to it
       (so you can add the Windows builds to a release created elsewhere)

  Only win32-x64 zips are produced/uploaded here; the macOS/Linux zips are built and
  published from a Mac (see release-portable.sh). Uploading to an existing release with
  --Clobber replaces same-named assets, so re-running is safe.

.PARAMETER Version
  Release tag. Accepts '1.18.1', 'v1.18.1' or 'portable-v1.18.1' (prefix added if missing).

.PARAMETER Repo
  GitHub owner/repo to publish to (default: hpeters83/tibco-developer-hub-fork).
.PARAMETER Target
  git ref the release tag points at (passed to gh --target), e.g. dev-hub-portable.
.PARAMETER Notes
  Release notes (used only when creating a new release).
.PARAMETER NotLatest
  Mark the release as NOT latest (gh --latest=false) when creating it.
.PARAMETER NoTechDocs
  Build/upload only the lean zip (skip the self-contained TechDocs variant).
.PARAMETER SkipBuild
  Reuse existing zips in DevHub_Portable\dist\ (no rebuild).
.PARAMETER SkipInstall
  Reuse existing node_modules during the build (passes -SkipInstall to build-bundled.ps1).
.PARAMETER NoTag
  Don't create/push a git tag (assume it already exists).
.PARAMETER Yes
  Don't prompt before publishing.

.EXAMPLE
  .\release-portable.ps1 portable-v1.18.1
.EXAMPLE
  .\release-portable.ps1 1.18.1 -SkipBuild        # just attach existing dist zips
.EXAMPLE
  .\release-portable.ps1 1.18.1 -Repo TIBCOSoftware/tibco-developer-hub -Target dev-hub-portable -NotLatest
#>
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Version,
  [string]$Repo = 'hpeters83/tibco-developer-hub-fork',
  [string]$Target = '',
  [string]$Notes = '',
  [switch]$NotLatest,
  [switch]$NoTechDocs,
  [switch]$SkipBuild,
  [switch]$SkipInstall,
  [switch]$NoTag,
  [switch]$Yes
)
$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Join-Path $ScriptDir 'DevHub_Portable'
$Dist        = Join-Path $PortableDir 'dist'

function Die($msg) { Write-Error "release-portable: $msg"; exit 1 }

# Normalise version: accept '1.18.1', 'v1.18.1' or 'portable-v1.18.1'.
if     ($Version -like 'portable-v*') { }
elseif ($Version -like 'v*')          { $Version = "portable-$Version" }
else                                  { $Version = "portable-v$Version" }
$Title = "DevHub Portable " + ($Version -replace '^portable-', '')
if (-not $Notes) {
  $Notes = "TechDocs: self-contained bundle variant (embedded Python + mkdocs) available alongside the standard build. Windows (win32-x64) builds attached."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Die "the GitHub CLI 'gh' is required (https://cli.github.com/)." }
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Die "gh is not authenticated. Run 'gh auth login' or set GH_TOKEN." }

Write-Host "==> Release plan"
Write-Host "    version : $Version"
Write-Host "    title   : $Title"
Write-Host "    repo    : $Repo"
if ($Target) { Write-Host "    target  : $Target" }
Write-Host ("    latest  : " + $(if ($NotLatest) { 'no' } else { 'yes' }))
Write-Host ("    build   : " + $(if ($SkipBuild) { 'no (reuse dist\)' } else { 'yes' }))
Write-Host ("    techdocs: " + $(if ($NoTechDocs) { 'no' } else { 'yes' }))
Write-Host ''

# --- 1. build ----------------------------------------------------------------
if (-not $SkipBuild) {
  Write-Host "==> [1/3] Building Windows bundle(s)"
  $buildArgs = @()
  if ($SkipInstall) { $buildArgs += '-SkipInstall' }
  if (-not $NoTechDocs) { $buildArgs += '-TechDocs' }
  & (Join-Path $PortableDir 'scripts\build-bundled.ps1') @buildArgs
  if ($LASTEXITCODE -ne 0) { Die "build-bundled.ps1 failed (exit $LASTEXITCODE)." }
} else {
  Write-Host "==> [1/3] Skipping build (-SkipBuild)"
}

# Only publish the Windows zips from this machine (matches both lean + techdocs names).
$zips = Get-ChildItem -Path (Join-Path $Dist 'devhub-bundled-*win32-x64.zip') -ErrorAction SilentlyContinue
if ($NoTechDocs) { $zips = $zips | Where-Object { $_.Name -notlike '*techdocs*' } }
if (-not $zips -or $zips.Count -eq 0) { Die "no win32-x64 zips found in $Dist — build first or drop them in." }
Write-Host "==> Artifacts to publish:"
$zips | ForEach-Object { Write-Host "    $($_.Name)" }
Write-Host ''

# --- confirm -----------------------------------------------------------------
if (-not $Yes) {
  $reply = Read-Host "Tag, push and publish '$Version' to $Repo? [y/N]"
  if ($reply -notmatch '^[Yy]$') { Die "aborted." }
}

# --- 2. tag ------------------------------------------------------------------
if (-not $NoTag) {
  Write-Host "==> [2/3] Tagging $Version"
  & git rev-parse -q --verify "refs/tags/$Version" *> $null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "    tag $Version already exists locally - reusing."
  } else {
    & git tag -a $Version -m $Title
    if ($LASTEXITCODE -ne 0) { Die "git tag failed." }
  }
  & git push origin $Version
  if ($LASTEXITCODE -ne 0) { Die "git push of tag failed." }
} else {
  Write-Host "==> [2/3] Skipping tag (-NoTag)"
}

# --- 3. publish (create, or upload to an existing release) -------------------
Write-Host "==> [3/3] Publishing to GitHub"
$zipPaths = $zips | ForEach-Object { $_.FullName }

& gh release view $Version --repo $Repo *> $null
if ($LASTEXITCODE -eq 0) {
  # Release exists — add/replace the Windows assets.
  Write-Host "    release $Version exists — uploading Windows zip(s) with --clobber"
  & gh release upload $Version @zipPaths --repo $Repo --clobber
  if ($LASTEXITCODE -ne 0) { Die "gh release upload failed." }
} else {
  # Release doesn't exist — create it with the Windows assets.
  Write-Host "    creating release $Version"
  $ghArgs = @('release', 'create', $Version) + $zipPaths + @('--repo', $Repo, '--title', $Title, '--notes', $Notes)
  if ($Target)    { $ghArgs += @('--target', $Target) }
  if ($NotLatest) { $ghArgs += '--latest=false' } else { $ghArgs += '--latest' }
  & gh @ghArgs
  if ($LASTEXITCODE -ne 0) { Die "gh release create failed." }
}

Write-Host ''
Write-Host "==> Done. Published $Version to $Repo."
